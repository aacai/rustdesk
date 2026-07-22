import 'dart:async';

import 'package:flutter/material.dart';
import 'package:settings_ui/settings_ui.dart';

import '../../common.dart';
import '../../common/mqtt_coordinator.dart';

/// MQTT 指令发送页 —— 以功能为导向，一键发送对应 MQTT 指令。
///
/// 长按「家庭监控」标题进入此页面。每个操作对应协议中的一个 action，
/// 自动填充 requestId / ts / expireAt / deviceId，用户无需手动拼 JSON。
class MqttSendPage extends StatefulWidget {
  const MqttSendPage({Key? key}) : super(key: key);

  @override
  State<MqttSendPage> createState() => _MqttSendPageState();
}

class _MqttSendPageState extends State<MqttSendPage> {
  String _deviceId = '';
  bool _mqttConnected = false;

  StreamSubscription<bool>? _connSub;
  StreamSubscription<void>? _devicesSub;

  @override
  void initState() {
    super.initState();
    _mqttConnected = MqttCoordinator.instance.controllerConnected;
    _connSub = MqttCoordinator.instance.onControllerConnection.listen((v) {
      if (mounted) setState(() => _mqttConnected = v);
    });
    _devicesSub = MqttCoordinator.instance.onDevicesChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _devicesSub?.cancel();
    super.dispose();
  }

  void _send(String action, Map<String, dynamic> params) {
    final did = _deviceId.trim();
    if (did.isEmpty) {
      showToast('请先输入目标 deviceId');
      return;
    }
    final sent = MqttCoordinator.instance.publishCmd(did, action, params);
    if (!sent) {
      showToast('发送失败：MQTT 未连接');
      return;
    }
    showToast('已发送 $action → $did');
  }

  void _showGrantDialog() {
    final ctrlId = TextEditingController();
    final ttlCtrl = TextEditingController(text: '7200');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('授权控制'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrlId,
              decoration: const InputDecoration(
                labelText: '控制端 RustDesk ID *',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ttlCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '有效秒数（默认 7200）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final cid = ctrlId.text.trim();
              if (cid.isEmpty) return;
              final ttl = int.tryParse(ttlCtrl.text.trim()) ?? 7200;
              Navigator.pop(ctx);
              _send('grant_access', {'controllerId': cid, 'ttlSec': ttl});
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  void _showRevokeDialog() {
    final ctrlId = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销授权'),
        content: TextField(
          controller: ctrlId,
          decoration: const InputDecoration(
            labelText: '控制端 RustDesk ID *',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final cid = ctrlId.text.trim();
              if (cid.isEmpty) return;
              Navigator.pop(ctx);
              _send('revoke_access', {'controllerId': cid});
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  // ---- 通用 tile 构建 ----

  SettingsTile _actionTile(String title, String action, Map<String, dynamic> params) {
    return SettingsTile(
      title: Text(title),
      trailing: ElevatedButton(
        onPressed: () => _send(action, params),
        child: const Text('发送'),
      ),
    );
  }

  SettingsTile _dialogTile(String title, VoidCallback onTap) {
    return SettingsTile(
      title: Text(title),
      trailing: ElevatedButton(
        onPressed: onTap,
        child: const Text('发送'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = MqttCoordinator.instance.devices;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios),
        ),
        title: const Text('MQTT 指令发送'),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(children: [
              Icon(_mqttConnected ? Icons.check_circle : Icons.error,
                  color: _mqttConnected ? Colors.green : Colors.red, size: 16),
              const SizedBox(width: 4),
              Text(_mqttConnected ? '已连接' : '未连接',
                  style: const TextStyle(fontSize: 12)),
            ]),
          ),
        ],
      ),
      body: SettingsList(sections: [
        // 设备选择
        SettingsSection(
          title: const Text('目标设备'),
          tiles: [
            SettingsTile(
              title: TextField(
                controller: TextEditingController(text: _deviceId),
                decoration: const InputDecoration(
                  labelText: 'deviceId',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => _deviceId = v,
              ),
            ),
            if (devices.isNotEmpty)
              SettingsTile(
                title: const Text('在线设备（点击填入）'),
                description: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: devices.map<Widget>((dev) {
                    final id = dev['deviceId']?.toString() ?? '';
                    final rd = dev['rustdeskId']?.toString() ?? '';
                    final ip = dev['ip']?.toString() ?? '';
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(id, style: const TextStyle(fontSize: 13)),
                      subtitle: Text('RD: $rd  IP: $ip',
                          style: const TextStyle(fontSize: 11)),
                      trailing: _deviceId == id
                          ? const Icon(Icons.check_circle, color: Colors.green, size: 18)
                          : null,
                      onTap: () => setState(() => _deviceId = id),
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
        // 策略控制
        SettingsSection(
          title: const Text('策略控制'),
          tiles: [
            _actionTile('启用心跳', 'set_policy', {'heartbeatEnabled': true}),
            _actionTile('禁用心跳', 'set_policy', {'heartbeatEnabled': false}),
            _actionTile('允许被控', 'set_policy', {'autoAcceptIncoming': true}),
            _actionTile('禁止被控', 'set_policy', {'autoAcceptIncoming': false}),
            _actionTile('自动接听开', 'set_policy', {'autoAnswerVoiceCall': true}),
            _actionTile('自动接听关', 'set_policy', {'autoAnswerVoiceCall': false}),
            _actionTile('看门狗开', 'set_policy', {'watchdogEnabled': true}),
            _actionTile('看门狗关', 'set_policy', {'watchdogEnabled': false}),
            _actionTile('获取策略', 'get_policy', {}),
          ],
        ),
        // 授权管理
        SettingsSection(
          title: const Text('授权管理'),
          tiles: [
            _dialogTile('授权控制', _showGrantDialog),
            _dialogTile('撤销授权', _showRevokeDialog),
            _actionTile('撤销全部授权', 'revoke_all_access', {}),
            _actionTile('查看授权列表', 'list_grants', {}),
          ],
        ),
        // 运维
        SettingsSection(
          title: const Text('运维'),
          tiles: [
            _actionTile('Ping', 'ping', {}),
            _actionTile('获取状态', 'get_status', {}),
            _actionTile('拉起服务', 'revive', {}),
            _actionTile('启动 RustDesk', 'start_rustdesk', {}),
          ],
        ),
        // 版本
        SettingsSection(
          title: const Text('版本'),
          tiles: [
            _actionTile('检查更新', 'get_update_info', {}),
          ],
        ),
      ]),
    );
  }
}
