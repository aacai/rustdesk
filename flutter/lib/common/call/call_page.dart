import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/common/call/call_manager.dart';

/// Shows the call UI globally. Called on both ends as soon as a call starts, so
/// the callee (e.g. the controlled device) can see and hear the peer too.
Future<void> showCallUi() async {
  await Get.dialog(
    const VideoCallDialog(),
    barrierDismissible: false,
  );
}

class VideoCallDialog extends StatelessWidget {
  const VideoCallDialog({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final manager = CallManager.instance;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: Colors.black,
      child: SizedBox(
        width: MediaQuery.of(context).size.width.clamp(280.0, 760.0).toDouble(),
        height:
            MediaQuery.of(context).size.height.clamp(360.0, 560.0).toDouble(),
        child: Stack(
          children: [
            Positioned.fill(
              child: RTCVideoView(
                manager.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              width: 176,
              height: 132,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ColoredBox(
                  color: Colors.black54,
                  child: RTCVideoView(
                    manager.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: _roundButton(
                icon: Icons.close,
                color: Colors.black45,
                onPressed: () => _hangup(context, manager),
              ),
            ),
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: _controls(context, manager),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context, CallManager manager) {
    return ValueListenableBuilder<CallState>(
      valueListenable: manager.state,
      builder: (_, st, __) {
        if (st == CallState.idle) {
          return Center(
            child: _roundButton(
              icon: Icons.call,
              color: Colors.green,
              size: 56,
              onPressed: manager.call,
            ),
          );
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: manager.micOn,
              builder: (_, on, __) => _roundButton(
                icon: on ? Icons.mic : Icons.mic_off,
                color: on ? Colors.white24 : Colors.red,
                onPressed: manager.toggleMic,
              ),
            ),
            const SizedBox(width: 20),
            ValueListenableBuilder<bool>(
              valueListenable: manager.cameraOn,
              builder: (_, on, __) => _roundButton(
                icon: on ? Icons.videocam : Icons.videocam_off,
                color: on ? Colors.white24 : Colors.red,
                onPressed: manager.toggleCamera,
              ),
            ),
            const SizedBox(width: 20),
            _roundButton(
              icon: Icons.call_end,
              color: Colors.red,
              onPressed: () => _hangup(context, manager),
            ),
          ],
        );
      },
    );
  }

  Future<void> _hangup(BuildContext context, CallManager manager) async {
    await manager.hangup();
    if (context.mounted) Navigator.of(context).maybePop();
  }

  Widget _roundButton({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    double size = 48,
  }) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: size * 0.5),
        ),
      ),
    );
  }
}
