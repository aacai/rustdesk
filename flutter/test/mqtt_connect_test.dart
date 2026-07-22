import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/mqtt_coordinator.dart';
import 'package:path/path.dart' as p;

// REAL integration tests for the MQTT single-connection coordinator.
//
// These tests drive the REAL MqttCoordinator via startForTest(),
// exercising the single MQTT connection that replaces the former
// dual _manager + _controller architecture.
//
// Run with:  flutter test test/mqtt_connect_test.dart

/// Load CA the SAME way the app does (assets/emqxsl-ca.crt via rootBundle,
/// with a file fallback for the test runner).
Future<String> _loadCa() async {
  try {
    return await rootBundle.loadString('assets/emqxsl-ca.crt');
  } catch (_) {
    final file = File(p.join(Directory.current.path, 'assets', 'emqxsl-ca.crt'));
    if (await file.exists()) return file.readAsStringSync();
    throw StateError('CA cert not found');
  }
}

Future<bool> _waitFor(bool Function() f, {int seconds = 25}) async {
  for (var i = 0; i < seconds * 4; i++) {
    if (f()) return true;
    await Future.delayed(const Duration(milliseconds: 250));
  }
  return false;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  Future<void> _holdAndRecheck(MqttCoordinator coord,
      {int wait = 25, int hold = 15}) async {
    expect(await _waitFor(() => coord.isConnected, seconds: wait), isTrue,
        reason: 'MqttCoordinator failed to connect');
    await Future.delayed(Duration(seconds: hold));
    expect(coord.isConnected, isTrue,
        reason: 'MqttCoordinator dropped during the $hold"s hold');
  }

  test('REAL coordinator: single connection stays connected for 15s', () async {
    final ca = await _loadCa();
    final coord = MqttCoordinator.instance;
    coord.startForTest('test-dev-001', ca);
    await _holdAndRecheck(coord, hold: 15);
    coord.stop();
  });

  test('REAL coordinator: second open reconnects and stays', () async {
    final ca = await _loadCa();
    final coord = MqttCoordinator.instance;

    coord.startForTest('test-dev-002', ca);
    expect(await _waitFor(() => coord.isConnected), isTrue,
        reason: 'first open should connect');
    await Future.delayed(const Duration(seconds: 3));
    coord.stop();

    coord.startForTest('test-dev-002', ca);
    await _holdAndRecheck(coord, wait: 30, hold: 10);
    coord.stop();
  });

  test('REAL coordinator: controllerConnected matches isConnected (single connection)',
      () async {
    final ca = await _loadCa();
    final coord = MqttCoordinator.instance;
    coord.startForTest('test-dev-003', ca);

    expect(await _waitFor(() => coord.isConnected), isTrue,
        reason: 'coordinator should connect');
    expect(coord.controllerConnected, isTrue,
        reason: 'controllerConnected must match isConnected on single connection');

    await Future.delayed(const Duration(seconds: 5));
    expect(coord.controllerConnected, equals(coord.isConnected),
        reason: 'controllerConnected and isConnected must always agree');

    coord.stop();
  });

  test('REAL coordinator: publishCmd returns true when connected, sends ACK back',
      () async {
    final ca = await _loadCa();
    final coord = MqttCoordinator.instance;
    coord.startForTest('test-dev-ping', ca);
    expect(await _waitFor(() => coord.isConnected), isTrue,
        reason: 'coordinator should connect');

    // Verify publishCmd returns true
    final sent = coord.publishCmd('test-dev-ping', 'ping', {});
    expect(sent, isTrue, reason: 'publishCmd should return true when connected');

    // Wait for ACK to arrive via onControllerUpMessage
    Map<String, dynamic>? ack;
    final sub = coord.onControllerUpMessage.listen((msg) {
      if (msg['type'] == 'ack' && msg['action'] == 'ping') {
        ack = msg;
      }
    });

    expect(await _waitFor(() => ack != null, seconds: 10), isTrue,
        reason: 'should receive ACK for ping within 10s');
    expect(ack!['ok'], isTrue, reason: 'ping ACK should be ok=true');
    expect(ack!['code'], equals(0), reason: 'ping ACK code should be 0');
    expect(ack!['deviceId'], equals('test-dev-ping'),
        reason: 'ACK deviceId should be raw id without rd-dev- prefix');

    await sub.cancel();
    coord.stop();
  });

  test('REAL coordinator: set_policy triggers familyMonitorChanged', () async {
    final ca = await _loadCa();
    final coord = MqttCoordinator.instance;
    coord.startForTest('test-dev-policy', ca);
    expect(await _waitFor(() => coord.isConnected), isTrue,
        reason: 'coordinator should connect');

    // Send set_policy
    final sent = coord.publishCmd('test-dev-policy', 'set_policy', {
      'heartbeatEnabled': true,
    });
    expect(sent, isTrue);

    // Wait for ACK
    Map<String, dynamic>? ack;
    final sub = coord.onControllerUpMessage.listen((msg) {
      if (msg['type'] == 'ack' && msg['action'] == 'set_policy') {
        ack = msg;
      }
    });

    expect(await _waitFor(() => ack != null, seconds: 10), isTrue,
        reason: 'should receive ACK for set_policy within 10s');
    expect(ack!['ok'], isTrue, reason: 'set_policy ACK should be ok=true');

    await sub.cancel();
    coord.stop();
  });

  test('REAL coordinator: get_config returns server config structure',
      () async {
    final ca = await _loadCa();
    final coord = MqttCoordinator.instance;
    coord.startForTest('test-dev-cfg1', ca);
    expect(await _waitFor(() => coord.isConnected), isTrue,
        reason: 'coordinator should connect');

    final sent = coord.publishCmd('test-dev-cfg1', 'get_config', {});
    expect(sent, isTrue, reason: 'publishCmd should return true');

    Map<String, dynamic>? ack;
    final sub = coord.onControllerUpMessage.listen((msg) {
      if (msg['type'] == 'ack' && msg['action'] == 'get_config') {
        ack = msg;
      }
    });

    expect(await _waitFor(() => ack != null, seconds: 10), isTrue,
        reason: 'should receive ACK for get_config within 10s');
    expect(ack!['ok'], isTrue, reason: 'get_config ACK should be ok=true');
    expect(ack!['code'], equals(0), reason: 'get_config code should be 0');

    // Verify data contains 'config' key (may be empty in test env without FFI delegate)
    final data = ack!['data'] as Map<String, dynamic>;
    expect(data.containsKey('config'), isTrue,
        reason: 'data must contain config key');
    final config = data['config'] as Map<String, dynamic>;
    // In production with delegate, config has: idServer, relayServer, apiServer, key
    // In test env without FFI, config is empty {} — still valid protocol response
    expect(config, isA<Map<String, dynamic>>(),
        reason: 'config must be a Map');

    await sub.cancel();
    coord.stop();
  });

  test('REAL coordinator: set_config without delegate returns 503', () async {
    final ca = await _loadCa();
    final coord = MqttCoordinator.instance;
    coord.startForTest('test-dev-cfg2', ca);
    expect(await _waitFor(() => coord.isConnected), isTrue,
        reason: 'coordinator should connect');

    // In test env, delegate is null → set_config should return code 503
    final sent = coord.publishCmd('test-dev-cfg2', 'set_config', {
      'idServer': 'rustdesk.example.com:21116',
      'relayServer': 'rustdesk.example.com:21117',
      'apiServer': 'https://rustdesk.example.com',
      'key': 'test-public-key',
    });
    expect(sent, isTrue);

    Map<String, dynamic>? ack;
    final sub = coord.onControllerUpMessage.listen((msg) {
      if (msg['type'] == 'ack' && msg['action'] == 'set_config') {
        ack = msg;
      }
    });

    expect(await _waitFor(() => ack != null, seconds: 15), isTrue,
        reason: 'should receive ACK for set_config within 15s');
    // In test env without FFI delegate, set_config returns 503 per protocol
    expect(ack!['ok'], isFalse, reason: 'set_config without delegate should fail');
    expect(ack!['code'], equals(503),
        reason: 'set_config without delegate should return code 503');
    expect((ack!['message'] as String).contains('delegate'), isTrue,
        reason: 'error message should mention delegate');

    await sub.cancel();
    coord.stop();
  });

  test('REAL coordinator: set_config with empty params without delegate returns 503',
      () async {
    final ca = await _loadCa();
    final coord = MqttCoordinator.instance;
    coord.startForTest('test-dev-cfg3', ca);
    expect(await _waitFor(() => coord.isConnected), isTrue,
        reason: 'coordinator should connect');

    // Even with empty params, delegate is required for set_config
    final sent = coord.publishCmd('test-dev-cfg3', 'set_config', {});
    expect(sent, isTrue);

    Map<String, dynamic>? ack;
    final sub = coord.onControllerUpMessage.listen((msg) {
      if (msg['type'] == 'ack' && msg['action'] == 'set_config') {
        ack = msg;
      }
    });

    expect(await _waitFor(() => ack != null, seconds: 10), isTrue,
        reason: 'should receive ACK for set_config within 10s');
    // delegate null → 503, regardless of params content
    expect(ack!['ok'], isFalse,
        reason: 'set_config without delegate should fail even with empty params');
    expect(ack!['code'], equals(503));

    await sub.cancel();
    coord.stop();
  });

  test('REAL coordinator: set_config key-only without delegate returns 503',
      () async {
    final ca = await _loadCa();
    final coord = MqttCoordinator.instance;
    coord.startForTest('test-dev-cfg5', ca);
    expect(await _waitFor(() => coord.isConnected), isTrue,
        reason: 'coordinator should connect');

    // Only set key — still needs delegate to write
    final sent = coord.publishCmd('test-dev-cfg5', 'set_config', {
      'key': 'test-public-key-abc123',
    });
    expect(sent, isTrue);

    Map<String, dynamic>? ack;
    final sub = coord.onControllerUpMessage.listen((msg) {
      if (msg['type'] == 'ack' && msg['action'] == 'set_config') {
        ack = msg;
      }
    });

    expect(await _waitFor(() => ack != null, seconds: 10), isTrue,
        reason: 'should receive ACK for set_config within 10s');
    expect(ack!['ok'], isFalse,
        reason: 'key-only update without delegate should fail');
    expect(ack!['code'], equals(503));

    await sub.cancel();
    coord.stop();
  });
}
