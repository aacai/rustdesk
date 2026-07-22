import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// Topic constants (ref: docs/家庭监控-MQTT协议.md §4).
const String kTopicCmd = 'rd/v1/cmd';
const String kTopicUp = 'rd/v1/up';
const String kTopicSysVersion = 'rd/v1/sys/version';

/// Pure MQTT manager — handles connection, publish, subscribe, heartbeat
/// timer, incoming command dispatch, dedup, rate limiting, and ACK/event
/// publishing.  No FFI, no local options, no policy knowledge.
///
/// Application-level side effects (FFI reads/writes, Kotlin method channels)
/// are injected via [MqttDelegate].
class MqttManager {
  MqttManager({
    required String host,
    required int port,
    required String username,
    required String password,
    required String caCertPem,
    required String clientId,
    this.delegate,
    int keepAliveSec = 60,
    int heartbeatIntervalSec = 10,
    int maxRetryDelaySec = 120,
  })  : _host = host,
        _port = port,
        _username = username,
        _password = password,
        _caCertPem = caCertPem,
        _clientId = clientId,
        _keepAliveSec = keepAliveSec,
        _heartbeatIntervalSec = heartbeatIntervalSec,
        _maxRetryDelaySec = maxRetryDelaySec;

  final String _host;
  final int _port;
  final String _username;
  final String _password;
  final String _caCertPem;
  final String _clientId;
  final int _keepAliveSec;
  final int _heartbeatIntervalSec;
  final int _maxRetryDelaySec;
  MqttDelegate? delegate;

  MqttServerClient? _client;
  Timer? _heartbeatTimer;
  Timer? _retryTimer;
  bool _connected = false;
  bool _stopping = false;
  bool _heartbeatEnabled = false;
  int _retryAttempt = 0;

  // Command dedup
  final Map<String, int> _recentRequestIds = {};
  int _rateWindowSec = 0;
  int _rateCount = 0;
  static const int _dedupMax = 200;
  static const int _rateLimitPerSec = 2;

  // Cached sys version
  Map<String, dynamic>? _cachedSysVersion;

  // Incoming parsed-command stream (for external consumers like settings page)
  final _cmdController = StreamController<MqttCommand>.broadcast();
  Stream<MqttCommand> get onCommand => _cmdController.stream;

  // Upstream message stream (for external consumers to receive kTopicUp / kTopicSysVersion messages)
  final _upMsgController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onUpMessage => _upMsgController.stream;

  // Connection state stream
  final _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get onConnectionChanged => _connectionController.stream;

  bool get isConnected => _connected;

  // ---------------------------------------- public API

  /// Connect to broker with automatic exponential-backoff retry.
  ///
  /// Reconnection (after a drop) is driven by [_onDisconnected]; both paths
  /// funnel through [connect] and use the same backoff. Connection state is
  /// owned by [_onConnected]/[_onDisconnected], not this method.
  void connect() {
    if (_stopping) return;
    debugPrint('[MqttManager] connect() called (host=$_host:$_port, clientId=$_clientId)');
    _connectOnce().then((_) {
      // State handled in _onConnected.
    }).catchError((e) {
      debugPrint('[MqttManager] connect() error: $e');
      if (_stopping) return;
      _scheduleReconnect('connect failed: $e');
    });
  }

  /// Exponential backoff: 3s, 6s, 12s … capped at [_maxRetryDelaySec].
  int _backoffDelay() {
    final exp = 1 << (_retryAttempt - 1).clamp(0, 31);
    return (3 * exp).clamp(2, _maxRetryDelaySec);
  }

  void _scheduleReconnect(String reason) {
    if (_stopping) return;
    _retryAttempt++;
    final delay = _backoffDelay();
    debugPrint('[MqttManager] attempt $_retryAttempt ($reason), retry in ${delay}s');
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: delay), connect);
  }

  /// Disconnect and cancel all timers.
  void disconnect() {
    _stopping = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    stopHeartbeat();
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
    if (_connected) {
      _connected = false;
      _connectionController.add(false);
    }
  }

  /// Start periodic heartbeat. Calls [MqttDelegate.buildHeartbeatPayload] each tick.
  void startHeartbeat() {
    stopHeartbeat();
    _heartbeatEnabled = true;
    _heartbeatTimer = Timer.periodic(
      Duration(seconds: _heartbeatIntervalSec),
      (_) {
        final raw = delegate?.buildHeartbeatPayload();
        if (raw != null) {
          try {
            final payload = jsonDecode(raw) as Map<String, dynamic>;
            payload['type'] = 'heartbeat';
            _publish(kTopicUp, jsonEncode(payload), MqttQos.atLeastOnce);
          } catch (_) {
            _publish(kTopicUp, raw, MqttQos.atLeastOnce);
          }
        }
      },
    );
    final first = delegate?.buildHeartbeatPayload();
    if (first != null) {
      try {
        final payload = jsonDecode(first) as Map<String, dynamic>;
        payload['type'] = 'heartbeat';
        _publish(kTopicUp, jsonEncode(payload), MqttQos.atLeastOnce);
      } catch (_) {
        _publish(kTopicUp, first, MqttQos.atLeastOnce);
      }
    }
  }

  void stopHeartbeat() {
    _heartbeatEnabled = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Publish a raw string payload to [topic].
  void publish(String topic, String payload, [MqttQos qos = MqttQos.atLeastOnce]) {
    _publish(topic, payload, qos);
  }

  /// Publish a command envelope to kTopicCmd.
  void publishCmd(Map<String, dynamic> payload) {
    _publish(kTopicCmd, jsonEncode(payload), MqttQos.atLeastOnce);
  }

  // ---------------------------------------- connect internal

  Future<void> _connectOnce() async {
    // Per the TS reference client, connect over WebSocket Secure (wss) to the
    // EMQX 8084 listener (path /mqtt) with the xiangqi_player account — not
    // raw MQTT/TLS on 8883. mqtt_client needs the full wss:// URL (incl. /mqtt)
    // plus the alternate WS implementation for wss to work.
    final server = 'wss://$_host:$_port/mqtt';
    final client = MqttServerClient(server, _clientId);
    client.port = _port;
    client.keepAlivePeriod = _keepAliveSec;
    client.autoReconnect = false;
    client.useWebSocket = true;
    client.useAlternateWebSocketImplementation = true;
    client.websocketProtocols = ['mqtt'];
    client.onConnected = _onConnected;
    client.onDisconnected = _onDisconnected;
    client.onSubscribed = _onSubscribed;
    client.connectTimeoutPeriod = 20;

    final context = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(utf8.encode(_caCertPem));
    client.securityContext = context;

    final msg = MqttConnectMessage()
      ..withClientIdentifier(_clientId)
      ..authenticateAs(_username, _password)
      ..withWillTopic(kTopicUp)
      ..withWillMessage(jsonEncode({
          'type': 'event',
          'v': 1,
          'event': 'offline_hint',
          'deviceId': _clientId,
          'ts': DateTime.now().millisecondsSinceEpoch,
          'data': {},
        }))
      ..startClean();

    _client = client;
    client.connectionMessage = msg;
    await client.connect();
  }

  void _onConnected() {
    debugPrint('[MqttManager] connected');
    _retryAttempt = 0;
    _connected = true;
    _connectionController.add(true);
    _client!.subscribe(kTopicCmd, MqttQos.atLeastOnce);
    _client!.subscribe(kTopicSysVersion, MqttQos.atLeastOnce);
    _client!.subscribe(kTopicUp, MqttQos.atLeastOnce);
    delegate?.onMqttConnected();
    _client!.updates!.listen(_onRawMessage);
    if (_heartbeatEnabled) startHeartbeat();
  }

  void _onDisconnected() {
    debugPrint('[MqttManager] disconnected');
    stopHeartbeat();
    if (_connected) {
      _connected = false;
      _connectionController.add(false);
    }
    delegate?.onMqttDisconnected();
    if (!_stopping) _scheduleReconnect('disconnected');
  }

  void _onSubscribed(String topic) {
    debugPrint('[MqttManager] subscribed: $topic');
  }

  // ---------------------------------------- raw message → parsed command

  void _onRawMessage(List<MqttReceivedMessage<MqttMessage>> msgs) {
    for (final msg in msgs) {
      final topic = msg.topic;
      final recv = msg.payload as MqttPublishMessage;
      final raw = MqttPublishPayload.bytesToStringAsString(recv.payload.message);

      if (topic == kTopicSysVersion) {
        try {
          _cachedSysVersion = jsonDecode(raw) as Map<String, dynamic>;
          _upMsgController.add({'topic': topic, ..._cachedSysVersion!});
        } catch (_) {}
        continue;
      }
      if (topic == kTopicUp) {
        try {
          final json = jsonDecode(raw) as Map<String, dynamic>;
          _upMsgController.add({'topic': topic, ...json});
        } catch (_) {}
        continue;
      }
      if (topic != kTopicCmd) continue;

      // ————— Parse command envelope —————
      Map<String, dynamic> json;
      try {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        _publishAck('', 'unknown', false, 400, 'bad json', {});
        continue;
      }
      if (json['v'] != 1) continue;

      final requestId = json['requestId'] as String? ?? '';
      final action = (json['action'] as String? ?? '').toLowerCase();

      // Target check — match against clientId or the raw deviceId suffix.
      // clientId is "rd-dev-{deviceId}", but commands use the raw deviceId.
      final target = json['deviceId'] as String? ?? '';
      final rawDeviceId = _clientId.startsWith('rd-dev-')
          ? _clientId.substring(7) : _clientId;
      if (target.isNotEmpty && target != '*' && target != _clientId && target != rawDeviceId) continue;

      // Sensitive actions without specific target
      if (_isSensitive(action) && (target.isEmpty || target == '*')) {
        _publishAck(requestId, action, false, 400, 'deviceId required', {});
        continue;
      }

      // Expiry
      final expireAt = json['expireAt'] as int? ?? 0;
      final ts = json['ts'] as int? ?? 0;
      final effectiveExpire = expireAt > 0
          ? expireAt
          : ts > 0 ? ts + 120000 : 0;
      if (effectiveExpire > 0 && DateTime.now().millisecondsSinceEpoch > effectiveExpire) {
        _publishAck(requestId, action, false, 408, 'expired', {});
        continue;
      }

      // Dedup
      if (requestId.isNotEmpty && _isDuplicate(requestId)) {
        _publishAck(requestId, action, false, 409, 'duplicate', {});
        continue;
      }

      // Rate limit
      if (!_allowRate()) {
        _publishAck(requestId, action, false, 429, 'rate limited', {});
        continue;
      }

      if (requestId.isNotEmpty) _markHandled(requestId);

      // Emit to external consumers (e.g. settings page)
      final params = json['params'] as Map<String, dynamic>? ?? {};
      _cmdController.add(MqttCommand(requestId: requestId, action: action, params: params));

      // Handle built-in actions
      _handleBuiltIn(requestId, action, params);
    }
  }

  // ---------------------------------------- command dispatch (built-in)

  Future<void> _handleBuiltIn(
      String requestId, String action, Map<String, dynamic> params) async {
    switch (action) {
      case 'ping':
        _publishAck(requestId, action, true, 0, 'ok', {});
        break;
      case 'status':
      case 'get_status':
        _publishAck(requestId, action, true, 0, 'ok', delegate?.buildStatus() ?? {});
        break;
      case 'get_policy':
        _publishAck(requestId, action, true, 0, 'ok', delegate?.buildPolicy() ?? {});
        break;
      case 'set_policy':
        delegate?.applyPolicy(params);
        _publishAck(requestId, action, true, 0, 'ok', delegate?.buildPolicy() ?? {});
        break;
      case 'get_config':
        _publishAck(requestId, action, true, 0, 'ok',
            {'config': delegate?.getConfig() ?? {}});
        break;
      case 'set_config':
        if (delegate == null) {
          _publishAck(requestId, action, false, 503, 'delegate missing', {});
          break;
        }
        final err = await delegate!.applyConfig(params);
        if (err != null) {
          _publishAck(requestId, action, false, 400, err, {});
        } else {
          _publishAck(requestId, action, true, 0, 'ok',
              {'config': delegate!.getConfig()});
        }
        break;
      case 'get_update_info':
        final ver = _cachedSysVersion ?? {};
        final appVer = delegate?.appVersion ?? '';
        final latest = ver['latestVersion'] as String? ?? '';
        _publishAck(requestId, action, true, 0, 'ok', {
          'appVersion': appVer,
          'needUpdate': latest.isNotEmpty && latest != appVer,
          'latest': ver,
        });
        break;
      case 'grant_access':
      case 'revoke_access':
      case 'revoke_all_access':
      case 'list_grants':
        final data = delegate?.handleGrant(action, params) ??
            {'ok': false, 'code': 503, 'message': 'delegate missing'};
        final ok = data['ok'] == true;
        _publishAck(
          requestId,
          action,
          ok,
          ok ? 0 : (data['code'] ?? 400),
          data['message'] ?? (ok ? 'ok' : 'failed'),
          data,
        );
        break;
      case 'revive':
      case 'start_rustdesk':
      case 'enable_watchdog':
      case 'disable_watchdog':
      case 'reboot_app':
        // These actions require native-side implementation; acknowledge receipt.
        _publishAck(requestId, action, true, 0, 'received', {});
        break;
      default:
        _publishAck(requestId, action, false, 404, 'unknown action', {});
        break;
    }
  }

  bool _isSensitive(String action) => [
        'grant_access', 'revoke_access', 'revoke_all_access',
        'set_policy', 'set_config', 'set_network', 'grant',
        'open_download', 'request_media_projection',
      ].contains(action);

  bool _isDuplicate(String requestId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentRequestIds.removeWhere((k, v) => now - v > 600000);
    return _recentRequestIds.containsKey(requestId);
  }

  void _markHandled(String requestId) {
    if (_recentRequestIds.length >= _dedupMax) {
      _recentRequestIds.remove(_recentRequestIds.keys.first);
    }
    _recentRequestIds[requestId] = DateTime.now().millisecondsSinceEpoch;
  }

  bool _allowRate() {
    final sec = DateTime.now().second;
    if (sec != _rateWindowSec) {
      _rateWindowSec = sec;
      _rateCount = 0;
    }
    return ++_rateCount <= _rateLimitPerSec;
  }

  // ---------------------------------------- publish helpers

  void _publish(String topic, String payload, MqttQos qos) {
    if (!isConnected) return;
    try {
      _client!.publishMessage(topic, qos, MqttClientPayloadBuilder().addString(payload).payload!);
    } catch (e) {
      debugPrint('[MqttManager] publish $topic: $e');
    }
  }

  void _publishAck(String requestId, String action, bool ok, int code, String message,
      Map<String, dynamic> data) {
    // Use raw deviceId (without rd-dev- prefix) to match protocol expectations.
    final ackDeviceId = _clientId.startsWith('rd-dev-')
        ? _clientId.substring(7) : _clientId;
    _publish(
        kTopicUp,
        jsonEncode({
          'type': 'ack',
          'v': 1,
          'requestId': requestId,
          'action': action,
          'ok': ok,
          'code': code,
          'message': message,
          'deviceId': ackDeviceId,
          'ts': DateTime.now().millisecondsSinceEpoch,
          'data': data,
        }),
        MqttQos.atLeastOnce);
  }
}

/// Parsed incoming MQTT command.
class MqttCommand {
  final String requestId;
  final String action;
  final Map<String, dynamic> params;

  MqttCommand({required this.requestId, required this.action, required this.params});
}

/// Callbacks for application-level side effects (FFI, Kotlin channels, etc).
abstract class MqttDelegate {
  void onMqttConnected() {}
  void onMqttDisconnected() {}
  String? buildHeartbeatPayload() => null;
  Map<String, dynamic> buildStatus() => {};
  Map<String, dynamic> buildPolicy() => {};
  void applyPolicy(Map<String, dynamic> params) {}
  Map<String, dynamic> handleGrant(String action, Map<String, dynamic> params) =>
      {'ok': false, 'code': 501, 'message': 'unsupported'};
  Map<String, dynamic> getConfig() => {};
  Future<String?> applyConfig(Map<String, dynamic> params) async => null;
  String get appVersion => '';
}
