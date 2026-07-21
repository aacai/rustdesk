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
}
