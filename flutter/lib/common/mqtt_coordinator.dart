import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:meta/meta.dart';
import 'package:mqtt_client/mqtt_client.dart';

import '../consts.dart';
import 'mqtt_manager.dart';

// Broker config shared by device-side manager and monitor-side controller so
// integration tests exercise the exact same parameters as production.
const String _kMqttHost = 's5ebe39b.ala.cn-hangzhou.emqxsl.cn';
const int _kMqttPort = 8084;
const String _kMqttUser = 'xiangqi_player';
const String _kMqttPass = 'xiangqi2024';

/// Coordinates MQTT connection with FFI options and native Android features.
///
/// Owns a [MqttManager] and implements [MqttDelegate] to bridge between pure
/// MQTT and application-layer concerns (FFI local options, Kotlin method
/// channels for watchdog/keep-alive).
class MqttCoordinator with WidgetsBindingObserver {
  MqttCoordinator._();

  static final MqttCoordinator instance = MqttCoordinator._();

  /// Conditionally print MQTT logs based on the log-enabled option.
  static void log(String message) {
    if (mainGetLocalBoolOptionSync(kOptionMqttLogEnabled)) {
      debugPrint(message);
    }
  }

  MqttManager? _manager;
  bool _started = false;
  bool _starting = false;
  String _deviceId = '';
  /// The device id used for MQTT client/topic identity (never empty once started).
  String get deviceId => _deviceId;

  final _connectionController = StreamController<bool>.broadcast();

  /// Emits MQTT connection state changes (true = connected).
  Stream<bool> get onConnectionChanged => _connectionController.stream;

  bool get isConnected => _manager?.isConnected ?? false;

  bool get controllerConnected => _manager?.isConnected ?? false;
  Stream<bool> get onControllerConnection => _connectionController.stream;

  // Dedicated relay controller so subscribers always get messages,
  // even if they subscribed before _manager was created.
  final _upMsgRelay = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onControllerUpMessage => _upMsgRelay.stream;

  /// 在线设备列表，由 `rd/v1/up` 心跳 / 事件维护（内存态，90s 无更新即过期）。
  /// 单例常驻，任何页面 / 无页面打开时都可读、可监听。
  final Map<String, Map<String, dynamic>> _devices = {};
  final StreamController<void> _devicesChanged =
      StreamController<void>.broadcast();
  List<Map<String, dynamic>> get devices {
    final now = DateTime.now().millisecondsSinceEpoch;
    _devices.removeWhere((_, v) => (v['lastSeen'] as int? ?? 0) < now - 90000);
    return _devices.values.toList();
  }

  Stream<void> get onDevicesChanged => _devicesChanged.stream;

  /// Publish a command envelope to the command topic from the control side.
  /// Returns `true` if the command was published (MQTT connected), `false` otherwise.
  bool publishCmd(
      String deviceId, String action, Map<String, dynamic> params) {
    final mgr = _manager;
    if (mgr == null || !mgr.isConnected) return false;
    mgr.publishCmd({
      'v': 1,
      'requestId':
          'c-${DateTime.now().millisecondsSinceEpoch}-${DateTime.now().microsecond}',
      'deviceId': deviceId.isEmpty ? '*' : deviceId,
      'action': action,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'expireAt': DateTime.now().millisecondsSinceEpoch + 120000,
      'params': params,
    });
    return true;
  }

  /// Publish a check-update request (get_update_info) to the command topic.
  /// Sends once on call. Returns `true` if the command was published (MQTT connected),
  /// `false` when MQTT is not connected so the caller can surface feedback.
  bool sendCheckUpdate() {
    final mgr = _manager;
    if (mgr == null || !mgr.isConnected) {
      log('[MqttCoordinator] sendCheckUpdate skipped: not connected');
      return false;
    }
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
    log('[MqttCoordinator] sendCheckUpdate published to $kTopicCmd');
    return true;
  }

  // ---------------------------------------- start / stop

  Future<void> start() async {
    if (_started) return;
    WidgetsBinding.instance.addObserver(this);
    _started = true;
    try {
      _deviceId = await bind.mainGetMyId();
    } catch (e) {
      log('[MqttCoordinator] mainGetMyId failed: $e');
      _deviceId = '';
    }
    log('[MqttCoordinator] start() deviceId="$_deviceId"');
    if (_deviceId.isEmpty) {
      _scheduleRetryId();
      return;
    }
    _doStart();
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _stopNativeForegroundService();
    _updateMqttStatusToNative(false);
    _started = false;
    familyMonitorChanged.removeListener(_onPolicyChanged);
    _retryTimer?.cancel();
    _configCheckTimer?.cancel();
    _configCheckTimer = null;
    _manager?.disconnect();
    _manager = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Back to foreground: check MQTT and reconnect if needed
      if (_started && _manager != null && !_manager!.isConnected) {
        log('[MqttCoordinator] app resumed, reconnecting MQTT');
        _manager!.connect();
      }
    }
  }

  /// Called when RustDesk ID becomes available later (e.g. after service start).
  Future<void> retry() async {
    if (_started) return;
    try {
      _deviceId = await bind.mainGetMyId();
    } catch (e) {
      log('[MqttCoordinator] mainGetMyId (retry) failed: $e');
      return;
    }
    if (_deviceId.isNotEmpty) {
      _retryTimer?.cancel();
      _doStart();
    }
  }

  // ---------------------------------------- internal

  Timer? _retryTimer;

  void _scheduleRetryId() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 5), () async {
      try {
        _deviceId = await bind.mainGetMyId();
      } catch (e) {
        log('[MqttCoordinator] mainGetMyId (retry) failed: $e');
        _scheduleRetryId();
        return;
      }
      if (_deviceId.isEmpty) {
        _scheduleRetryId();
        return;
      }
      _doStart();
    });
  }

  /// Load the EMQX CA cert. Prefer bundled asset; fall back to a file on disk
  /// so a transient asset-load failure (e.g. before the Flutter asset system is
  /// fully ready) does not silently leave MQTT permanently disconnected.
  Future<String> _loadCaPem() async {
    try {
      final pem = await rootBundle.loadString('assets/emqxsl-ca.crt');
      if (pem.isNotEmpty) {
        log('[MqttCoordinator] CA loaded from asset (${pem.length} bytes)');
        return pem;
      }
    } catch (e) {
      log('[MqttCoordinator] CA asset load failed: $e');
    }
    // Fallback: common on-device locations.
    final candidates = [
      'assets/emqxsl-ca.crt',
      'emqxsl-ca.crt',
    ];
    for (final p in candidates) {
      try {
        final file = File(p);
        if (await file.exists()) {
          final pem = await file.readAsString();
          if (pem.isNotEmpty) {
            log('[MqttCoordinator] CA loaded from file ($p, ${pem.length} bytes)');
            return pem;
          }
        }
      } catch (e) {
        log('[MqttCoordinator] CA file load failed ($p): $e');
      }
    }
    throw StateError('EMQX CA certificate not found (asset or file)');
  }

  void _doStart() {
    if (_starting || _manager != null) return;
    _starting = true;
    _started = true;

    final caPem = _loadCaPem();
    final clientId = 'rd-dev-$_deviceId';

    const host = _kMqttHost;
    const port = _kMqttPort; // wss listener (path /mqtt), per TS reference client
    const username = _kMqttUser;
    const password = _kMqttPass;

    caPem.then((pem) {
      log('[MqttCoordinator] CA loaded (${pem.length} bytes), creating manager');
      _applyConnectionDefaults();
      _manager = MqttManager(
        host: host,
        port: port,
        username: username,
        password: password,
        caCertPem: pem,
        clientId: clientId,
        delegate: _MqttFfiDelegate(),
      )..logEnabled = mainGetLocalBoolOptionSync(kOptionMqttLogEnabled);

      familyMonitorChanged.addListener(_onPolicyChanged);
      // Push current policy to Kotlin on startup
      _pushPolicyToNative();
      // Start the periodic remote-config check (default once a day).
      _restartConfigCheckTimer();
      _manager!.onConnectionChanged.listen((c) {
        _connectionController.add(c);
        if (c) {
          _startNativeForegroundService();
          _updateMqttStatusToNative(true);
        } else {
          _updateMqttStatusToNative(false);
        }
      });
      _connectionController.add(_manager!.isConnected);
      _manager!.connect();
      _manager!.onUpMessage.listen(_onUpMessage);

      _starting = false;
    }).catchError((e) {
      _starting = false;
      log('[MqttCoordinator] CA load failed: $e');
    });
  }

  /// Apply default connection-optimization settings for family-monitor usage.
  /// These are standard RustDesk options, not MQTT-specific.
  void _applyConnectionDefaults() {
    mainSetLocalBoolOption(kOptionEnableUdpPunch, true);
    mainSetLocalBoolOption(kOptionEnableIpv6Punch, true);
    bind.mainSetLocalOption(key: kOptionDirectServer, value: 'Y');
  }

  void _onPolicyChanged() {
    // Sync heartbeat with MQTT. Always restart when enabled so a changed
    // heartbeat interval takes effect immediately.
    if (_manager != null && _manager!.isConnected) {
      final hbOn = mainGetLocalBoolOptionSync(kOptionMqttHeartbeat);
      if (hbOn) {
        _manager!.startHeartbeat();
      } else {
        _manager!.stopHeartbeat();
      }
    }
    // Rebuild the remote-config check timer with the latest interval.
    _restartConfigCheckTimer();
    // Push to Kotlin (always, even if MQTT disconnected)
    _pushPolicyToNative();
  }

  void _pushPolicyToNative() {
    final policy = {
      'watchdogEnabled': mainGetLocalBoolOptionSync(kOptionMqttWatchdog),
      'heartbeatEnabled': mainGetLocalBoolOptionSync(kOptionMqttHeartbeat),
      'autoAcceptIncoming': mainGetLocalBoolOptionSync(kOptionMqttAutoAccept),
      'autoAnswerVoiceCall': mainGetLocalBoolOptionSync(kOptionMqttAutoAnswerVoice),
    };
    gFFI.invokeMethod(AndroidChannel.kSetFamilyPolicy, jsonEncode(policy));
    gFFI.serverModel.applyFamilyMqttPolicy(policy);
  }

  void _startNativeForegroundService() {
    if (Platform.isAndroid) {
      gFFI.invokeMethod(AndroidChannel.kStartMqttForeground);
    }
  }

  void _stopNativeForegroundService() {
    if (Platform.isAndroid) {
      gFFI.invokeMethod(AndroidChannel.kStopMqttForeground);
    }
  }

  void _updateMqttStatusToNative(bool connected) {
    if (Platform.isAndroid) {
      gFFI.invokeMethod('update_mqtt_status', {'connected': connected});
    }
  }

  /// Update the [MqttManager.logEnabled] flag when the user toggles the log switch.
  void updateManagerLogEnabled(bool v) {
    _manager?.logEnabled = v;
  }

  /// Called by native side to check and reconnect MQTT if disconnected.
  void checkAndReconnect() {
    if (_started && _manager != null && !_manager!.isConnected) {
      log('[MqttCoordinator] native triggered reconnect');
      _manager!.connect();
    }
  }

  /// Test-only: start the single MQTT connection with an injected deviceId
  /// and CA, bypassing the FFI-dependent startup.
  @visibleForTesting
  void startForTest(String deviceId, String caPem) {
    _deviceId = deviceId;
    _started = true;
    _starting = false;

    final clientId = 'rd-dev-$_deviceId';
    _manager = MqttManager(
      host: _kMqttHost,
      port: _kMqttPort,
      username: _kMqttUser,
      password: _kMqttPass,
      caCertPem: caPem,
      clientId: clientId,
    );
    _manager!.onConnectionChanged.listen((c) => _connectionController.add(c));
    _connectionController.add(_manager!.isConnected);
    _manager!.connect();
    _manager!.onUpMessage.listen(_onUpMessage);
  }

  /// 单例内部始终消费上行消息：按 deviceId 维护在线设备快照，并转发给外部订阅者。
  void _onUpMessage(Map<String, dynamic> msg) {
    // Relay to external consumers (e.g. MqttSendPage)
    _upMsgRelay.add(msg);
    // Remote config lives in the retained rd/v1/sys/version payload; apply it
    // in real time whenever it arrives / changes.
    if (msg['topic'] == kTopicSysVersion) {
      _maybeApplyRemoteConfig(msg);
      return;
    }
    final id = msg['deviceId']?.toString();
    if (id == null || id.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _devices[id] = {...msg, 'lastSeen': now};
    _devicesChanged.add(null);
  }

  // ---------------------------------------- remote config (sys/version)

  Timer? _configCheckTimer;
  bool _applyingRemoteConfig = false;

  /// Remote-config check interval in minutes (default one day to save power).
  int get _configCheckIntervalMin {
    final v = int.tryParse(
        bind.mainGetLocalOption(key: kOptionMqttConfigCheckIntervalMin));
    return (v == null || v <= 0) ? 1440 : v;
  }

  void _restartConfigCheckTimer() {
    _configCheckTimer?.cancel();
    _configCheckTimer = Timer.periodic(
      Duration(minutes: _configCheckIntervalMin),
      (_) => checkRemoteConfigNow(),
    );
  }

  /// Check the (retained) remote config now and apply if it differs.
  /// Called on settings-page open, on the periodic timer, and whenever a fresh
  /// sys/version message arrives.
  Future<void> checkRemoteConfigNow() async {
    final cached = _manager?.cachedSysVersion;
    if (cached != null) {
      await _maybeApplyRemoteConfig(cached);
    }
    // If not cached yet, the broker pushes the retained message on
    // (re)subscribe, which flows into _onUpMessage → _maybeApplyRemoteConfig.
  }

  /// Apply `config` from the sys/version payload when `not_equal_then_replace`
  /// is true and any non-empty field differs from the local value.
  Future<void> _maybeApplyRemoteConfig(Map<String, dynamic> json) async {
    if (json['not_equal_then_replace'] != true) return;
    final cfg = json['config'];
    if (cfg is! Map) return;
    if (_applyingRemoteConfig) return;

    final delegate = _MqttFfiDelegate();
    final local = delegate.getConfig();
    String norm(dynamic v) {
      final s = (v ?? '').toString().trim();
      return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
    }

    final fields = <String, dynamic>{
      'idServer': cfg['idServer'],
      'relayServer': cfg['relayServer'],
      'apiServer': cfg['apiServer'],
      'key': cfg['key'],
    };
    var diff = false;
    fields.forEach((k, v) {
      final want = norm(v);
      if (want.isEmpty) return; // only compare non-empty remote fields
      if (norm(local[k]) != want) diff = true;
    });
    if (!diff) return;

    _applyingRemoteConfig = true;
    try {
      // Forced replace: skip reachability validation so the config is applied
      // even when the target server is momentarily offline.
      final err = await delegate.applyConfig(fields, validate: false);
      if (err != null) {
        debugPrint('[MqttCoordinator] remote config apply failed: $err');
      } else {
        debugPrint('[MqttCoordinator] remote config applied');
      }
    } finally {
      _applyingRemoteConfig = false;
    }
  }
}

/// Delegate that bridges MQTT events to FFI local options.
class _MqttFfiDelegate extends MqttDelegate {
  _MqttFfiDelegate();

  @override
  int? heartbeatIntervalSec() {
    final v = int.tryParse(
        bind.mainGetLocalOption(key: kOptionMqttHeartbeatIntervalSec));
    return (v == null || v <= 0) ? null : v;
  }

  @override
  String? buildHeartbeatPayload() {
    if (!mainGetLocalBoolOptionSync(kOptionMqttHeartbeat)) return null;
    final id = MqttCoordinator.instance.deviceId;
    if (id.isEmpty) return null;
    return jsonEncode({
      'v': 1,
      'deviceId': id,
      'rustdeskId': id,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'appVersion': '1.4.9',
      // Advertise the interval so the monitor side can size its offline
      // timeout (max(90s, 2.5 × interval)).
      'hbIntervalSec': heartbeatIntervalSec() ?? 10,
    });
  }

  @override
  Map<String, dynamic> buildPolicy() => {
        'heartbeatEnabled': mainGetLocalBoolOptionSync(kOptionMqttHeartbeat),
        'autoAcceptIncoming': mainGetLocalBoolOptionSync(kOptionMqttAutoAccept),
        'autoAnswerVoiceCall': mainGetLocalBoolOptionSync(kOptionMqttAutoAnswerVoice),
      };

  @override
  Map<String, dynamic> handleGrant(String action, Map<String, dynamic> params) {
    return gFFI.serverModel.handleFamilyGrant(action, params);
  }

  @override
  void applyPolicy(Map<String, dynamic> params) {
    final map = {
      kOptionMqttHeartbeat: params['heartbeatEnabled'],
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
  Future<String?> applyConfig(Map<String, dynamic> params,
      {bool validate = true}) async {
    String trimOrNull(dynamic v) {
      if (v == null) return '';
      final s = v.toString().trim();
      return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
    }

    final id = trimOrNull(params['idServer']);
    final relay = trimOrNull(params['relayServer']);
    final api = trimOrNull(params['apiServer']);
    final key = (params['key']?.toString() ?? '').trim();

    if (validate) {
      if (id.isNotEmpty) {
        final err =
            await bind.mainTestIfValidServer(server: id, testWithProxy: true);
        if (err.isNotEmpty) return 'idServer: $err';
      }
      if (relay.isNotEmpty) {
        final err = await bind.mainTestIfValidServer(
            server: relay, testWithProxy: true);
        if (err.isNotEmpty) return 'relayServer: $err';
      }
      if (api.isNotEmpty &&
          !api.startsWith('http://') &&
          !api.startsWith('https://')) {
        return 'apiServer: invalid_http';
      }
    }

    // Write non-restart-triggering options first so they are already persisted
    // before custom-rendezvous-server forces a RendezvousMediator restart.
    if (key.isNotEmpty) {
      await bind.mainSetOption(key: 'key', value: key);
    }
    if (relay.isNotEmpty) {
      await bind.mainSetOption(key: 'relay-server', value: relay);
    }
    if (api.isNotEmpty) {
      await bind.mainSetOption(key: 'api-server', value: api);
    }
    // Write id last to trigger a restart that picks up the fresh key/relay.
    if (id.isNotEmpty) {
      await bind.mainSetOption(key: 'custom-rendezvous-server', value: id);
    } else if (key.isNotEmpty || relay.isNotEmpty) {
      // No id change, but key/relay changed: force a restart by rewriting the
      // current custom-rendezvous-server value (same value still restarts).
      final cur = bind.mainGetOptionSync(key: 'custom-rendezvous-server');
      await bind.mainSetOption(key: 'custom-rendezvous-server', value: cur);
    }
    return null;
  }

  @override
  Map<String, dynamic> buildStatus() => {
        'deviceId': MqttCoordinator.instance.deviceId,
        'mqttConnected': true,
        'heartbeatEnabled': mainGetLocalBoolOptionSync(kOptionMqttHeartbeat),
        'appVersion': '1.4.9',
      };

  @override
  String get appVersion => '1.4.9';
}


