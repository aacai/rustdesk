import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:path/path.dart' as p;

// Standalone MQTT connectivity diagnostic.
//
// Run with:  flutter test test/mqtt_connect_test.dart
//
// It tries to connect with the same broker parameters used by the app and
// prints the exact failure reason so the "连不上" problem can be located
// (network / credentials / TLS / CA).

const String kHost = 's5ebe39b.ala.cn-hangzhou.emqxsl.cn';
const int kPort = 8883;
const String kUsername = 'd91a4b87';
const String kPassword = 'E-PBKk3Bw_pU88zN';

Future<String> _loadCa() async {
  final file = File(p.join(Directory.current.path, 'assets', 'emqxsl-ca.crt'));
  if (!await file.exists()) {
    throw StateError('CA cert not found at ${file.path}');
  }
  return file.readAsStringSync();
}

Future<MqttServerClient?> _tryConnect({
  required String clientId,
  required String caPem,
  required bool customCa,
  String uname = kUsername,
  String pass = kPassword,
  int timeout = 15,
}) async {
  final client = MqttServerClient(kHost, clientId);
  client.port = kPort;
  client.keepAlivePeriod = 60;
  client.autoReconnect = false;
  client.secure = true;
  client.connectTimeoutPeriod = timeout;
  // NOTE: do NOT use `client.onBadCertificate =` — mqtt_client 10.5.1 casts
  // it to `bool Function(Object)?` and throws at runtime. Rely on the loaded
  // CA (the app's MqttManager does the same and connects fine).
  final ctx = SecurityContext(withTrustedRoots: true);
  if (customCa) {
    ctx.setTrustedCertificatesBytes(utf8.encode(caPem));
  }
  client.securityContext = ctx;
  client.connectionMessage = MqttConnectMessage()
    ..withClientIdentifier(clientId)
    ..authenticateAs(uname, pass)
    ..startClean();
  try {
    await client.connect();
    final ok = client.connectionStatus?.state == MqttConnectionState.connected;
    print('  -> connected: $ok  (state=${client.connectionStatus?.state})');
    return ok ? client : null;
  } catch (e, st) {
    print('  -> FAILED: $e');
    print(st);
    return null;
  }
}

void main() {
  test('mqtt connect diagnostic', () async {
    final ca = await _loadCa();
    print('CA loaded, length=${ca.length}');

    print('--- A: custom CA (app device/controller style) ---');
    var c = await _tryConnect(
        clientId: 'test-a-${DateTime.now().millisecondsSinceEpoch}',
        caPem: ca,
        customCa: true);
    final aOk = c != null;
    c?.disconnect();

    print('--- B: system roots only (no custom CA) ---');
    c = await _tryConnect(
        clientId: 'test-b-${DateTime.now().millisecondsSinceEpoch}',
        caPem: ca,
        customCa: false);
    final bOk = c != null;
    c?.disconnect();

    print('--- C: swapped (secret as username, appid as password) ---');
    c = await _tryConnect(
        clientId: 'test-c-${DateTime.now().millisecondsSinceEpoch}',
        caPem: ca,
        customCa: true,
        uname: kPassword,
        pass: kUsername);
    final cOk = c != null;
    c?.disconnect();

    expect(aOk || bOk || cOk, isTrue,
        reason: 'All connect attempts failed — check network/credentials');
  });
}
