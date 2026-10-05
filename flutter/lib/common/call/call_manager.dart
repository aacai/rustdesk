import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_hbb/common.dart' show AndroidPermissionManager;
import 'package:flutter_hbb/common/call/call_page.dart';
import 'package:flutter_hbb/common/call/call_signal.dart';
import 'package:flutter_hbb/consts.dart' show kCamera, kRecordAudio;

/// Sends one encoded signaling payload to the peer (chat channel).
typedef CallSignalSender = void Function(String payload);

enum CallState { idle, calling, ringing, connected }

/// Bidirectional video call built on `flutter_webrtc`.
///
/// Media is captured, encoded, transported and rendered by libwebrtc directly
/// between the two Flutter clients; only the SDP/ICE signaling is relayed
/// through the RustDesk session. A single call is active at a time.
class CallManager {
  CallManager._();
  static final CallManager instance = CallManager._();

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  final ValueNotifier<CallState> state = ValueNotifier(CallState.idle);
  final ValueNotifier<bool> micOn = ValueNotifier(true);
  final ValueNotifier<bool> cameraOn = ValueNotifier(true);

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  CallSignalSender? _send;
  bool _renderersReady = false;
  bool uiVisible = false;

  bool get inCall => _pc != null;

  // A public STUN server is used for address discovery only; media is always
  // end-to-end encrypted by WebRTC. Replace with your own STUN/TURN for
  // networks where direct connectivity is impossible.
  static const Map<String, dynamic> _config = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  static const Map<String, dynamic> _mediaConstraints = {
    'audio': true,
    'video': {
      'facingMode': 'user',
      'width': {'ideal': 1280},
      'height': {'ideal': 720},
    },
  };

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
  }

  Future<MediaStream> _ensureLocalStream() async {
    if (_localStream != null) return _localStream!;
    // No-op on desktop/web; on Android libwebrtc needs the runtime permissions
    // granted before it can open the camera and microphone.
    if (!await AndroidPermissionManager.check(kCamera)) {
      await AndroidPermissionManager.request(kCamera);
    }
    if (!await AndroidPermissionManager.check(kRecordAudio)) {
      await AndroidPermissionManager.request(kRecordAudio);
    }
    _localStream =
        await navigator.mediaDevices.getUserMedia(_mediaConstraints);
    localRenderer.srcObject = _localStream;
    return _localStream!;
  }

  /// Binds the signaling sender and prepares the local preview.
  Future<void> open(CallSignalSender send) async {
    _send = send;
    await _ensureRenderers();
    await _ensureLocalStream();
  }

  /// Shows the call UI once (no-op while it is already on screen).
  void showUi() {
    if (uiVisible) return;
    uiVisible = true;
    showCallUi().whenComplete(() => uiVisible = false);
  }

  Future<RTCPeerConnection> _ensurePc() async {
    if (_pc != null) return _pc!;
    final pc = await createPeerConnection(_config);
    pc.onIceCandidate = (cand) {
      if (cand.candidate == null) return;
      _sendSignal(CallSignal('candidate', cand.toMap()));
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams[0];
      }
    };
    pc.onConnectionState = (st) {
      if (st == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        state.value = CallState.connected;
      } else if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          st == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        hangup();
      }
    };
    _pc = pc;
    return pc;
  }

  void _sendSignal(CallSignal s) => _send?.call(s.encode());

  /// Caller: create the offer and send it.
  Future<void> call() async {
    await _ensureRenderers();
    final stream = await _ensureLocalStream();
    final pc = await _ensurePc();
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    state.value = CallState.calling;
    _sendSignal(CallSignal('offer', {'sdp': offer.sdp, 'type': offer.type}));
    showUi();
  }

  /// Handles one inbound signaling payload (prefix already validated upstream).
  Future<void> onSignal(String text, CallSignalSender send) async {
    final signal = CallSignal.tryDecode(text);
    if (signal == null) return;
    _send = send;
    await _ensureRenderers();
    switch (signal.type) {
      case 'offer':
        await _onOffer(signal);
        break;
      case 'answer':
        await _onAnswer(signal);
        break;
      case 'candidate':
        await _onCandidate(signal);
        break;
      case 'bye':
        await hangup();
        break;
    }
  }

  Future<void> _onOffer(CallSignal s) async {
    if (_pc != null) return;
    state.value = CallState.ringing;
    final stream = await _ensureLocalStream();
    final pc = await _ensurePc();
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    await pc.setRemoteDescription(
        RTCSessionDescription(s.data['sdp'], s.data['type']));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    state.value = CallState.connected;
    _sendSignal(CallSignal('answer', {'sdp': answer.sdp, 'type': answer.type}));
    showUi();
  }

  Future<void> _onAnswer(CallSignal s) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(
        RTCSessionDescription(s.data['sdp'], s.data['type']));
  }

  Future<void> _onCandidate(CallSignal s) async {
    final pc = _pc;
    if (pc == null) return;
    try {
      await pc.addCandidate(RTCIceCandidate(
        s.data['candidate'],
        s.data['sdpMid'],
        s.data['sdpMLineIndex'],
      ));
    } catch (_) {
      // Candidate may arrive before the remote description; ignore.
    }
  }

  void toggleMic() {
    micOn.value = !micOn.value;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = micOn.value);
  }

  void toggleCamera() {
    cameraOn.value = !cameraOn.value;
    _localStream?.getVideoTracks().forEach((t) => t.enabled = cameraOn.value);
  }

  Future<void> hangup() async {
    if (_pc == null && _localStream == null) return;
    _sendSignal(CallSignal('bye', const {}));
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    try {
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    state.value = CallState.idle;
    micOn.value = true;
    cameraOn.value = true;
  }
}
