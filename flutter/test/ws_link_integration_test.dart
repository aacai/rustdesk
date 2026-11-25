import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ============================================================================
/// WebSocket link test — HONEST edition.
///
/// Two kinds of checks:
///   1. Unit: checkWs address transform (mirrors Rust hbb_common::check_ws).
///      This ONLY proves the fork's transform logic is correct — it does NOT
///      prove the user's server can actually serve WSS. Do not mistake a green
///      here for "the bug is fixed".
///   2. REAL reachability probe against the user's actual OSS (192.168.50.1):
///      we really try to connect the WS rendezvous/relay ports and the TCP
///      ports. IMPORTANT: hbb_common::check_ws emits `ws://` (plaintext) for
///      IP-address hosts, NOT `wss://`. So the client actually dials
///      ws://host:21118 and ws://host:21119. Confirmed against the OSS:
///      curl -i http://192.168.50.1:21118 returns "HTTP/1.1 101 Switching
///      Protocols" (plaintext ws handshake works). The old OSS 1.1.14 did NOT
///      serve these ports at all, which is why the UI hung.
///      After upgrading the router OSS to 1.1.16, these probes should now reach
///      -> that is the real "fixed" signal.
///
/// Run:  flutter test test/ws_link_integration_test.dart
/// ============================================================================

// ---- Rust constants mirrored from hbb_common/src/config.rs -----------------
const int _kRendezvousPort = 21116;
const int _kRelayPort = 21117;

/// The user's real self-hosted OSS. Change if your deployment differs.
const String _kOssHost = '192.168.50.1';

class _Cfg {
  final Map<String, String> opts;
  _Cfg(this.opts);
  String getOption(String k) => opts[k] ?? '';
  bool useWs() => getOption('allow-websocket').toUpperCase() == 'Y';
}

(String host, int port)? _splitHostPort(String s) {
  if (s.isEmpty) return null;
  final idx = s.lastIndexOf(':');
  if (idx < 0) return null;
  final host = s.substring(0, idx);
  final port = int.tryParse(s.substring(idx + 1));
  if (host.isEmpty || port == null) return null;
  return (host, port);
}

bool _isIp(String host) => InternetAddress.tryParse(host) != null;

/// Faithful Dart port of hbb_common::websocket::check_ws (transform logic only).
String checkWs(String endpoint, _Cfg cfg) {
  if (!cfg.useWs()) return endpoint;
  if (endpoint.isEmpty) return endpoint;
  if (endpoint.startsWith('ws://') || endpoint.startsWith('wss://')) {
    return endpoint;
  }
  final hp = _splitHostPort(endpoint);
  if (hp == null) return endpoint;
  final (host, port) = hp;
  final rvServer = cfg.getOption('custom-rendezvous-server');
  final relayServer = cfg.getOption('relay-server');
  final rvPort = _splitHostPort(rvServer)?.$2 ?? _kRendezvousPort;
  final relayPort = _splitHostPort(relayServer)?.$2 ?? _kRelayPort;

  late int dstPort;
  late bool relay;
  if (port == rvPort) {
    relay = false;
    dstPort = port + 2;
  } else if (port == rvPort - 1) {
    relay = false;
    dstPort = port + 3;
  } else if (port == relayPort || port == rvPort + 1) {
    relay = true;
    dstPort = port + 2;
  } else {
    relay = true;
    dstPort = port + 2;
  }
  final isIp = _isIp(host);
  final protocol = isIp
      ? 'ws'
      : (cfg.getOption('api-server').startsWith('https') ? 'wss' : 'ws');
  final address = isIp ? '$host:$dstPort' : '$host${relay ? "/ws/relay" : "/ws/id"}';
  return '$protocol://$address';
}

Future<bool> _tcpReachable(String host, int port,
    {Duration timeout = const Duration(seconds: 3)}) async {
  try {
    final s = await Socket.connect(host, port, timeout: timeout);
    await s.close();
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> _wsReachable(String url,
    {Duration timeout = const Duration(seconds: 3)}) async {
  try {
    final ws = await WebSocket.connect(url).timeout(timeout);
    await ws.close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  // -------------------------------------------------------------------------
  // 1) Unit: checkWs transform — proves the fork logic matches Rust.
  //    GREEN HERE != bug fixed. It only proves the address rewrite is correct.
  // -------------------------------------------------------------------------
  group('checkWs transformation (mirrors Rust hbb_common)', () {
    test('disabled WS keeps endpoint unchanged (plain TCP path)', () {
      final cfg = _Cfg({'custom-rendezvous-server': '192.168.50.1:21116'});
      expect(checkWs('192.168.50.1:21116', cfg), '192.168.50.1:21116');
    });
    test('enabled WS rewrites rendezvous 21116 -> ws://..:21118', () {
      final cfg = _Cfg({
        'allow-websocket': 'Y',
        'custom-rendezvous-server': '192.168.50.1:21116',
      });
      expect(checkWs('192.168.50.1:21116', cfg), 'ws://192.168.50.1:21118');
    });
    test('enabled WS rewrites relay 21117 -> ws://..:21119', () {
      final cfg = _Cfg({
        'allow-websocket': 'Y',
        'custom-rendezvous-server': '192.168.50.1:21116',
        'relay-server': '192.168.50.1:21117',
      });
      expect(checkWs('192.168.50.1:21117', cfg), 'ws://192.168.50.1:21119');
    });
  });

  // -------------------------------------------------------------------------
  // 2) REAL probe against the user's actual OSS. This is the honest check.
  //    When "Use WebSocket" is ON, RustDesk dials ws://host:21118 (rendezvous)
  //    and ws://host:21119 (relay) — note: ws:// (plaintext), because the host
  //    is an IP address (check_ws only emits wss:// for domain + https api).
  //    On the OLD OSS 1.1.14 these ports were never served -> UI hung at
  //    "connecting to RustDesk network". After upgrading the router OSS to
  //    1.1.16, these endpoints ARE served, so the honest assertion is now
  //    reachable == true. Run this on a machine on the home LAN.
  // -------------------------------------------------------------------------
  group('REAL probe: user OSS ($_kOssHost)', () {
    test('WS rendezvous 21118 reachable (ws://) -> link should work', () async {
      final ok = await _wsReachable('ws://$_kOssHost:21118');
      // ignore: avoid_print
      print('[probe] ws://$_kOssHost:21118 reachable=$ok');
      expect(ok, isTrue,
          reason: 'After upgrading OSS to 1.1.16 the WS rendezvous endpoint '
              'must be reachable; if false the WS hang will persist.');
    });

    test('WS relay 21119 reachable (ws://) -> link should work', () async {
      final ok = await _wsReachable('ws://$_kOssHost:21119');
      // ignore: avoid_print
      print('[probe] ws://$_kOssHost:21119 reachable=$ok');
      expect(ok, isTrue,
          reason: 'After upgrading OSS to 1.1.16 the WS relay endpoint '
              'must be reachable.');
    });

    test('TCP rendezvous 21116 reachability (informational, not asserted)', () async {
      final ok = await _tcpReachable(_kOssHost, 21116);
      // ignore: avoid_print
      print('[probe] tcp://$_kOssHost:21116 reachable=$ok '
          '(true when on the home LAN & OSS running -> "Use WebSocket OFF" works)');
    });

    test('TCP relay 21117 reachability (informational, not asserted)', () async {
      final ok = await _tcpReachable(_kOssHost, 21117);
      // ignore: avoid_print
      print('[probe] tcp://$_kOssHost:21117 reachable=$ok');
    });
  });
}
