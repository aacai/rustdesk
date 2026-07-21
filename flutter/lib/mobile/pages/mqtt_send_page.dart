import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../common/mqtt_coordinator.dart';

/// Page for sending MQTT command envelopes to family-monitor devices.
///
/// Long-press "家庭监控" title on [ServerPage] opens this page. It composes
/// the protocol envelope (v / requestId / deviceId / action / ts / params)
/// and publishes it to [kTopicCmd] via [MqttCoordinator].
class MqttSendPage extends StatefulWidget {
  const MqttSendPage({Key? key}) : super(key: key);

  @override
  State<MqttSendPage> createState() => _MqttSendPageState();
}

class _MqttSendPageState extends State<MqttSendPage> {
  final _deviceIdCtrl = TextEditingController();
  final _paramsCtrl = TextEditingController(text: '{}');
  final List<Map<String, dynamic>> _log = [];
  final _pretty = const JsonEncoder.withIndent('  ');

  String _action = 'ping';
  StreamSubscription<Map<String, dynamic>>? _sub;

  static const List<String> _actions = [
    'ping',
    'get_status',
    'revive',
    'start_rustdesk',
    'enable_watchdog',
    'disable_watchdog',
    'reboot_app',
    'get_update_info',
    'open_download',
    'grant_access',
    'revoke_access',
    'revoke_all_access',
    'list_grants',
    'set_policy',
    'get_policy',
    'set_config',
    'get_config',
    'open_accessibility_settings',
    'open_overlay_settings',
    'request_media_projection',
    'notify',
  ];

  @override
  void initState() {
    super.initState();
    _sub = MqttCoordinator.instance.onControllerUpMessage.listen(_onUp);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _deviceIdCtrl.dispose();
    _paramsCtrl.dispose();
    super.dispose();
  }

  void _onUp(Map<String, dynamic> msg) {
    final copy = Map<String, dynamic>.from(msg)..remove('topic');
    _addLog('recv', _pretty.convert(copy), topic: msg['topic'] as String?);
  }

  void _addLog(String dir, String text, {String? topic, bool error = false}) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, {
        'dir': dir,
        'text': text,
        'topic': topic,
        'error': error,
        'ts': DateTime.now(),
      });
    });
  }

  void _send() {
    final deviceId = _deviceIdCtrl.text.trim();
    Map<String, dynamic> params = {};
    final raw = _paramsCtrl.text.trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          params = decoded;
        } else if (decoded is Map) {
          params = Map<String, dynamic>.from(decoded);
        } else {
          _addLog('send', 'params 必须是 JSON 对象', error: true);
          return;
        }
      } catch (e) {
        _addLog('send', '参数 JSON 解析失败: $e', error: true);
        return;
      }
    }
    if (!MqttCoordinator.instance.controllerConnected) {
      _addLog('send', 'MQTT 控制器未连接', error: true);
      return;
    }
    MqttCoordinator.instance.publishCmd(deviceId, _action, params);
    _addLog('send', _pretty.convert({
      'deviceId': deviceId.isEmpty ? '*' : deviceId,
      'action': _action,
      'params': params,
    }));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios),
        ),
        title: const Text('MQTT 参数发送'),
        centerTitle: true,
        actions: [
          StreamBuilder<bool>(
            initialData: MqttCoordinator.instance.controllerConnected,
            stream: MqttCoordinator.instance.onControllerConnection,
            builder: (c, snap) {
              final ok = snap.data ?? false;
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Row(children: [
                  Icon(ok ? Icons.check_circle : Icons.error,
                      color: ok ? Colors.green : Colors.red, size: 16),
                  const SizedBox(width: 4),
                  Text(ok ? '已连接' : '未连接',
                      style: const TextStyle(fontSize: 12)),
                ]),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _deviceIdCtrl,
                  decoration: const InputDecoration(
                    labelText: '目标 deviceId（留空或 * 为广播）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: _action,
                  decoration: const InputDecoration(
                    labelText: 'Action',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: _actions
                      .map((a) =>
                          DropdownMenuItem(value: a, child: Text(a)))
                      .toList(),
                  onChanged: (v) => setState(() => _action = v ?? _action),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _paramsCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'params（JSON，可留空 {}）',
                    border: OutlineInputBorder(),
                    isDense: true,
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _send,
                    child: const Text('发送'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _log.isEmpty
                ? const Center(child: Text('暂无消息'))
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: _log.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (c, i) {
                      final item = _log[i];
                      final isRecv = item['dir'] == 'recv';
                      final isErr = item['error'] == true;
                      final ts = (item['ts'] as DateTime)
                          .toString()
                          .substring(11, 19);
                      final topic = item['topic'] as String?;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isRecv ? Icons.arrow_downward : Icons.arrow_upward,
                          color: isRecv ? Colors.blue : Colors.orange,
                          size: 18,
                        ),
                        title: Text(
                          item['text'] as String,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: isErr ? Colors.red : null,
                          ),
                        ),
                        subtitle: Text(
                          '${isRecv ? '接收' : '发送'} $ts'
                          '${topic != null ? ' · $topic' : ''}',
                          style: const TextStyle(fontSize: 10),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
