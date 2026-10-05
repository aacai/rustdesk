import 'dart:convert';

/// Peer-to-peer video-call signaling messages (WebRTC offer/answer/ICE).
///
/// The signaling is tunnelled through the existing RustDesk chat channel, which
/// is the only bidirectional peer channel available with just the RustDesk
/// server and without regenerating the FFI bridge. Every message is prefixed
/// with [prefix] so it never reaches the chat UI.
///
/// This transport is intentionally isolated here so it can later be swapped for
/// a dedicated proto message without touching the call logic.
class CallSignal {
  static const String prefix = '@@RDCALL@@';

  /// One of: offer | answer | candidate | bye
  final String type;
  final Map<String, dynamic> data;

  CallSignal(this.type, this.data);

  String encode() => prefix + jsonEncode({'t': type, 'd': data});

  /// Returns the decoded signal, or null when [text] is a normal chat message.
  static CallSignal? tryDecode(String text) {
    if (!text.startsWith(prefix)) return null;
    try {
      final obj = jsonDecode(text.substring(prefix.length));
      if (obj is Map && obj['t'] is String && obj['d'] is Map) {
        return CallSignal(
            obj['t'] as String, (obj['d'] as Map).cast<String, dynamic>());
      }
    } catch (_) {
      // Malformed payload: treat as a normal chat message.
    }
    return null;
  }
}
