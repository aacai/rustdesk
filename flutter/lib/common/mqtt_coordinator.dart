import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../consts.dart';
import 'mqtt_manager.dart';

/// Coordinates MQTT connection with FFI options and native Android features.
///
/// Owns a [MqttManager] and implements [MqttDelegate] to bridge between pure
/// MQTT and application-layer concerns (FFI local options, Kotlin method
/// channels for watchdog/keep-alive).
class MqttCoordinator {
  MqttCoordinator._();

  static final MqttCoordinator instance = MqttCoordinator._();

  MqttManager? _manager;
  bool _started = false;
  String _deviceId = '';

  final _connectionController = StreamController<bool>.broadcast();

  /// Emits MQTT connection state changes (true = connected).
  Stream<bool> get onConnectionChanged => _connectionController.stream;

  bool get isConnected => _manager?.isConnected ?? false;

  // Controller (monitor / control side).
  _MqttController? _controller;

  bool get controllerConnected => _controller?.isConnected ?? false;
  Stream<bool> get onControllerConnection =>
      _controller?._connController.stream ?? const Stream.empty();
  Stream<Map<String, dynamic>> get onControllerUpMessage =>
      _controller?._msgController.stream ?? const Stream.empty();

  /// Publish a command envelope to the command topic from the control side.
  void publishCmd(
      String deviceId, String action, Map<String, dynamic> params) {
    _controller?.publishCmd({
      'v': 1,
      'requestId':
          'c-${DateTime.now().millisecondsSinceEpoch}-${DateTime.now().microsecond}',
      'deviceId': deviceId.isEmpty ? '*' : deviceId,
      'action': action,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'expireAt': DateTime.now().millisecondsSinceEpoch + 120000,
      'params': params,
    });
  }

  /// Publish a check-update request (get_update_info) to the command topic.
  /// Sends once on call; no-op when MQTT is not connected.
  void sendCheckUpdate() {
    final mgr = _manager;
    if (mgr == null || !mgr.isConnected) return;
    mgr.publish(
      kTopicCmd,
      jsonEncode({
        'v': 1,
        'requestId': 'cu-${DateTime.now().millisecondsSinceEpoch}',
        'deviceId': _deviceId,
        'action': 'get_update_info',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'params': {'openBrowser': false},
      }),
      MqttQos.atLeastOnce,
    );
  }

  // ---------------------------------------- start / stop

  Future<void> start() async {
    if (_started) return;
    _deviceId = bind.mainGetLocalOption(key: 'id');
    if (_deviceId.isEmpty) {
      _scheduleRetryId();
      return;
    }
    _doStart();
  }

  void stop() {
    _started = false;
    familyMonitorChanged.removeListener(_onPolicyChanged);
    _retryTimer?.cancel();
    _manager?.disconnect();
    _manager = null;
    _controller?.disconnect();
    _controller = null;
  }

  /// Called when RustDesk ID becomes available later (e.g. after service start).
  void retry() {
    if (_started) return;
    _deviceId = bind.mainGetLocalOption(key: 'id');
    if (_deviceId.isNotEmpty) {
      _retryTimer?.cancel();
      _doStart();
    }
  }

  // ---------------------------------------- internal

  Timer? _retryTimer;

  void _scheduleRetryId() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 5), () {
      _deviceId = bind.mainGetLocalOption(key: 'id');
      if (_deviceId.isEmpty) {
        _scheduleRetryId();
        return;
      }
      _doStart();
    });
  }

  void _doStart() {
    _started = true;

    final caPem = rootBundle.loadString('assets/emqxsl-ca.crt');
    final clientId = 'rd-dev-$_deviceId';

    final host = 's5ebe39b.ala.cn-hangzhou.emqxsl.cn';
    const port = 8883;
    const username = 'd91a4b87';
    const password = 'E-PBKk3Bw_pU88zN';

    caPem.then((pem) {
      _applyConnectionDefaults();
      _manager = MqttManager(
        host: host,
        port: port,
        username: username,
        password: password,
        caCertPem: pem,
        clientId: clientId,
        delegate: _MqttFfiDelegate(),
      );

      familyMonitorChanged.addListener(_onPolicyChanged);
      // Push current policy to Kotlin on startup
      _pushPolicyToNative();
      _manager!.onConnectionChanged.listen((c) => _connectionController.add(c));
      _connectionController.add(_manager!.isConnected);
      _manager!.connect();

      _startController(pem, host, port, username, password);
    });
  }

  void _startController(String pem, String host, int port, String username,
      String password) {
    if (_controller != null) return;
    final clientId = 'rd-ctl-$_deviceId-${DateTime.now().millisecondsSinceEpoch % 100000}';
    _controller = _MqttController(
      host: host,
      port: port,
      username: username,
      password: password,
      caCertPem: pem,
      clientId: clientId,
    );
    _controller!.connect();
  }

  /// Apply default connection-optimization settings for family-monitor usage.
  /// These are standard RustDesk options, not MQTT-specific.
  void _applyConnectionDefaults() {
    mainSetLocalBoolOption(kOptionEnableUdpPunch, true);
    mainSetLocalBoolOption(kOptionEnableIpv6Punch, true);
    bind.mainSetLocalOption(key: kOptionDirectServer, value: 'Y');
  }

  void _onPolicyChanged() {
    // Sync heartbeat with MQTT
    if (_manager != null && _manager!.isConnected) {
      final hbOn = mainGetLocalBoolOptionSync(kOptionMqttHeartbeat);
      if (hbOn) {
        _manager!.startHeartbeat();
      } else {
        _manager!.stopHeartbeat();
      }
    }
    // Push to Kotlin (always, even if MQTT disconnected)
    _pushPolicyToNative();
  }

  void _pushPolicyToNative() {
    final policy = {
      'watchdogEnabled': mainGetLocalBoolOptionSync(kOptionMqttWatchdog),
      'heartbeatEnabled': mainGetLocalBoolOptionSync(kOptionMqttHeartbeat),
      'autoAllowAny': mainGetLocalBoolOptionSync(kOptionMqttAutoAllowAny),
      'autoAcceptIncoming': mainGetLocalBoolOptionSync(kOptionMqttAutoAccept),
      'autoAnswerVoiceCall': mainGetLocalBoolOptionSync(kOptionMqttAutoAnswerVoice),
    };
    gFFI.invokeMethod(AndroidChannel.kSetFamilyPolicy, jsonEncode(policy));
    gFFI.serverModel.applyFamilyMqttPolicy(policy);
  }
}

/// Delegate that bridges MQTT events to FFI local options.
class _MqttFfiDelegate extends MqttDelegate {
  _MqttFfiDelegate();

  @override
  String? buildHeartbeatPayload() {
    if (!mainGetLocalBoolOptionSync(kOptionMqttHeartbeat)) return null;
    final id = bind.mainGetLocalOption(key: 'id');
    if (id.isEmpty) return null;
    return jsonEncode({
      'v': 1,
      'deviceId': id,
      'rustdeskId': id,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'appVersion': '1.4.9',
    });
  }

  @override
  @override
  Map<String, dynamic> buildPolicy() => {
        'heartbeatEnabled': mainGetLocalBoolOptionSync(kOptionMqttHeartbeat),
        'autoAllowAny': mainGetLocalBoolOptionSync(kOptionMqttAutoAllowAny),
        'autoAcceptIncoming': mainGetLocalBoolOptionSync(kOptionMqttAutoAccept),
        'autoAnswerVoiceCall': mainGetLocalBoolOptionSync(kOptionMqttAutoAnswerVoice),
      };

  @override
  void applyPolicy(Map<String, dynamic> params) {
    final map = {
      kOptionMqttHeartbeat: params['heartbeatEnabled'],
      kOptionMqttAutoAllowAny: params['autoAllowAny'],
      kOptionMqttAutoAccept: params['autoAcceptIncoming'],
      kOptionMqttAutoAnswerVoice: params['autoAnswerVoiceCall'],
    };
    for (final entry in map.entries) {
      if (entry.value != null) {
        mainSetLocalBoolOptionAndNotify(entry.key, entry.value == true);
      }
    }
  }

  @override
  Map<String, dynamic> getConfig() {
    final cfg = ServerConfig.fromOptions({
      'custom-rendezvous-server': bind.mainGetOptionSync(key: 'custom-rendezvous-server'),
      'relay-server': bind.mainGetOptionSync(key: 'relay-server'),
      'api-server': bind.mainGetOptionSync(key: 'api-server'),
      'key': bind.mainGetOptionSync(key: 'key'),
    });
    return {
      'idServer': cfg.idServer,
      'relayServer': cfg.relayServer,
      'apiServer': cfg.apiServer,
      'key': cfg.key,
    };
  }

  @override
  Future<String?> applyConfig(Map<String, dynamic> params) async {
    String trimOrNull(dynamic v) {
      if (v == null) return '';
      final s = v.toString().trim();
      return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
    }

    final id = trimOrNull(params['idServer']);
    final relay = trimOrNull(params['relayServer']);
    final api = trimOrNull(params['apiServer']);
    final key = (params['key']?.toString() ?? '').trim();

    if (id.isNotEmpty) {
      final err = await bind.mainTestIfValidServer(server: id, testWithProxy: true);
      if (err.isNotEmpty) return 'idServer: $err';
    }
    if (relay.isNotEmpty) {
      final err = await bind.mainTestIfValidServer(server: relay, testWithProxy: true);
      if (err.isNotEmpty) return 'relayServer: $err';
    }
    if (api.isNotEmpty &&
        !api.startsWith('http://') &&
        !api.startsWith('https://')) {
      return 'apiServer: invalid_http';
    }

    if (id.isNotEmpty) {
      await bind.mainSetOption(key: 'custom-rendezvous-server', value: id);
    }
    if (relay.isNotEmpty) {
      await bind.mainSetOption(key: 'relay-server', value: relay);
    }
    if (api.isNotEmpty) {
      await bind.mainSetOption(key: 'api-server', value: api);
    }
    if (key.isNotEmpty) {
      await bind.mainSetOption(key: 'key', value: key);
    }
    return null;
  }

  @override
  Map<String, dynamic> buildStatus() => {
        'deviceId': bind.mainGetLocalOption(key: 'id'),
        'mqttConnected': true,
        'heartbeatEnabled': mainGetLocalBoolOptionSync(kOptionMqttHeartbeat),
        'appVersion': '1.4.9',
      };

  @override
  String get appVersion => '1.4.9';
}

/// Lightweight MQTT client on the monitor/control side.
///
/// Subscribes to [kTopicUp] (and [kTopicSysVersion]) to receive device
/// heartbeats and command acks, and publishes command envelopes to
/// [kTopicCmd]. It does not run the device heartbeat/policy loop.
class _MqttController {
  _MqttController({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.caCertPem,
    required this.clientId,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String caCertPem;
  final String clientId;

  MqttServerClient? _client;
  bool _stopping = false;
  Timer? _retryTimer;
  int _retryAttempt = 0;

  final _msgController = StreamController<Map<String, dynamic>>.broadcast();
  final _connController = StreamController<bool>.broadcast();

  Stream<Map<String, dynamic>> get onUpMessage => _msgController.stream;
  Stream<bool> get onConnectionChanged => _connController.stream;

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  void connect() {
    if (_stopping) return;
    _connectOnce().catchError((e) {
      if (!_stopping) _scheduleReconnect('connect: $e');
    });
  }

  int _backoff() {
    final exp = 1 << (_retryAttempt.clamp(0, 31));
    return (3 * exp).clamp(2, 120);
  }

  void _scheduleReconnect(String reason) {
    if (_stopping) return;
    _retryAttempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: _backoff()), connect);
  }

  Future<void> _connectOnce() async {
    final client = MqttServerClient(host, clientId);
    client.port = port;
    client.keepAlivePeriod = 60;
    client.autoReconnect = false;
    client.secure = true;
    client.onConnected = _onConnected;
    client.onDisconnected = _onDisconnected;
    final context = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(utf8.encode(caCertPem));
    client.securityContext = context;
    client.connectionMessage = MqttConnectMessage()
      ..withClientIdentifier(clientId)
      ..authenticateAs(username, password)
      ..startClean();
    _client = client;
    await client.connect();
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      throw Exception('mqtt connect state=${client.connectionStatus?.state}');
    }
  }

  void _onConnected() {
    _retryAttempt = 0;
    _connController.add(true);
    _client!.subscribe(kTopicUp, MqttQos.atLeastOnce);
    _client!.subscribe(kTopicSysVersion, MqttQos.atLeastOnce);
    _client!.updates!.listen(_onRawMessage);
  }

  void _onDisconnected() {
    _connController.add(false);
    if (!_stopping) _scheduleReconnect('disconnected');
  }

  void _onRawMessage(List<MqttReceivedMessage<MqttMessage>> msgs) {
    for (final msg in msgs) {
      final recv = msg.payload as MqttPublishMessage;
      final raw =
          MqttPublishPayload.bytesToStringAsString(recv.payload.message);
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _msgController.add({'topic': msg.topic, ...json});
      } catch (_) {
        // ignore non-JSON payloads
      }
    }
  }

  void publishCmd(Map<String, dynamic> payload) {
    if (!isConnected) return;
    try {
      _client!.publishMessage(
        kTopicCmd,
        MqttQos.atLeastOnce,
        MqttClientPayloadBuilder().addString(jsonEncode(payload)).payload!,
      );
    } catch (e) {
      print('[MqttController] publish: $e');
    }
  }

  void disconnect() {
    _stopping = true;
    _retryTimer?.cancel();
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
  }
}
