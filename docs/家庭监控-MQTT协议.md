# 家庭监控 MQTT 协议（设备端 ↔ 监控端）

> 版本：`1.2.0`  
> 适用：老人机 / 被控 Android（RustDesk） ↔ 你的家庭监控客户端  
> 目标：**监控端下发指令即可完成控制**，尽量不需要被控端弹窗确认。

---

## 1. 设计原则

1. **监控端主导**：策略与开关一律由 MQTT 下发；设备端只执行并回报。
2. **Topic 固定，设备写在参数里**：你永远往同一个 topic 发指令，用 `deviceId` 字段指定目标；**不必事先知道 ID 也能先订阅心跳发现设备**。
3. **请求–响应**：每条指令带 `requestId`，设备用同一 `requestId` 回执，便于 UI 对账。
4. **幂等 + 过期**：指令可带 `expireAt`；过期指令丢弃；重复 `requestId` 在窗口内只执行一次。
5. **密钥不进 UI**：MQTT 连接信息打进 APK，用户无需再配置。

---

## 2. 连接参数（设备端内置，监控端复用同一 Broker）

| 项 | 值 |
|---|---|
| Broker | `s5ebe39b.ala.cn-hangzhou.emqxsl.cn` |
| 端口 | `8883`（MQTT over TLS） |
| 用户名 | `i2aea494` |
| 密码 | （与设备端一致，见内部配置） |
| CA | `emqxsl-ca.crt` |
| QoS | 指令 / 回执 / 心跳默认 **1** |
| KeepAlive | 60s |

设备 ClientId 建议：`rd-dev-{deviceId}-{suffix}`  
监控端 ClientId 建议：`rd-ctl-{userId}-{suffix}`

---

## 3. 设备 ID 是什么？怎么拿到？

你**不用提前知道** deviceId。

| 字段 | 来源 | 用途 |
|---|---|---|
| `deviceId` | Android `Settings.Secure.ANDROID_ID`（约 16 位十六进制） | MQTT 寻址、列表主键 |
| `rustdeskId` | RustDesk 业务 ID（界面上那个数字 ID） | 你真正发起远程连接时用 |
| `ip` | 设备当前局域网/出口 IP（尽力获取） | 排查网络、局域网辅助 |

**发现流程（推荐）：**

1. 监控端订阅固定 topic：`rd/v1/heartbeat`
2. 设备每 **10 秒**上报一次心跳（含 `deviceId`、`ts`、`ip`、`rustdeskId`…）
3. 你在 UI 里看到设备列表 → 选中某一台 → 发指令时把该 `deviceId` 填进参数

心跳可在设置 / `set_policy` 里关闭，**默认开启**。

---

## 4. Topic 规划（定稿：全部固定，不含 deviceId）

统一前缀：`rd/v1`

| Topic | 方向 | 说明 |
|---|---|---|
| `rd/v1/cmd` | 监控端 → 所有设备 | **唯一指令入口**；body 里带 `deviceId` 指定目标 |
| `rd/v1/ack` | 设备 → 监控端 | 指令回执（body 含 `deviceId`） |
| `rd/v1/event` | 设备 → 监控端 | 主动事件（body 含 `deviceId`） |
| `rd/v1/heartbeat` | 设备 → 监控端 | **每 10 秒**上报设备信息（发现用） |
| `rd/v1/sys/version` | 发布者 → 全体 | 最新 APK 版本与下载链接（**retained**） |

### 为什么这样定

- 你发指令永远 publish 到 **`rd/v1/cmd`**，不用拼 topic、不用记 ID 格式。
- 设备列表靠 **`rd/v1/heartbeat`** 自动冒出来；`deviceId` 从心跳里抄到指令参数即可。
- 所有设备都订 `rd/v1/cmd`，各自只处理 `deviceId` 匹配自己的消息；`deviceId` 为空或 `"*"` 表示广播（慎用）。

### 兼容说明

旧 topic（`rustdesk/cmd/{deviceId}` 等）实现阶段可短暂兼容；**监控端请只按本文档固定 topic 开发**。

---

## 5. 通用信封

### 5.1 下行指令（`rd/v1/cmd`）

```json
{
  "v": 1,
  "requestId": "uuid-or-unique-string",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "ping",
  "ts": 1710000000000,
  "expireAt": 1710000300000,
  "params": {}
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `v` | 是 | 协议版本，当前固定 `1` |
| `requestId` | 是 | 全局唯一；回执原样带回 |
| `deviceId` | 是* | 目标设备；`"*"` 或省略 = 广播所有在线设备（仅允许运维类，如 `ping`） |
| `action` | 是 | 见第 6 节 |
| `ts` | 建议 | 发送方毫秒时间戳 |
| `expireAt` | 否 | 超过则设备丢弃；默认 `ts + 120s` |
| `params` | 否 | 动作参数对象 |

\* `grant_access` / `set_policy` 等敏感操作 **必须** 带明确 `deviceId`，禁止广播。

### 5.2 上行回执（`rd/v1/ack`）

```json
{
  "v": 1,
  "requestId": "uuid-or-unique-string",
  "action": "ping",
  "ok": true,
  "code": 0,
  "message": "ok",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "ts": 1710000000100,
  "data": {}
}
```

| `code` | 含义 |
|---|---|
| `0` | 成功 |
| `400` | 参数错误 |
| `404` | 未知 action |
| `408` | 指令已过期 |
| `409` | 重复 requestId（已处理过） |
| `429` | 频率过高 |
| `500` | 内部错误 |
| `503` | 服务未就绪（如 MainService 未起、缺录屏授权） |
| `501` | 能力未实现 / 需系统权限无法静默完成 |

### 5.3 主动事件（`rd/v1/event`）

```json
{
  "v": 1,
  "event": "online",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "ts": 1710000000000,
  "data": {}
}
```

常见 `event`：

| event | 说明 |
|---|---|
| `online` | MQTT 已连上 |
| `offline_hint` | 即将断线（尽力而为，不可靠） |
| `service_up` / `service_down` | MainService 状态变化 |
| `permission_missing` | 缺权限（录屏 / 无障碍 / 悬浮窗等） |
| `session_started` / `session_ended` | 被控会话开始/结束 |
| `grant_expired` | 某次临时授权到期 |
| `update_available` | 本地版本低于 `sys/version` |

### 5.4 心跳上报（`rd/v1/heartbeat`）— 发现设备用

- 周期：**默认每 10 秒** 发一次（MQTT 连上后立即先发 1 次）
- QoS：1
- retain：**false**（靠周期刷新列表；超过约 30 秒无心跳可视为离线）
- 开关：设置页 / `set_policy.heartbeatEnabled`，**默认 `true`**

```json
{
  "v": 1,
  "deviceId": "a1b2c3d4e5f6g7h8",
  "rustdeskId": "123456789",
  "ts": 1710000000000,
  "ip": "192.168.1.23",
  "appVersion": "1.4.9",
  "mainServiceRunning": true,
  "battery": 87,
  "charging": false
}
```

| 字段 | 必有 | 说明 |
|---|---|---|
| `deviceId` | 是 | MQTT 寻址 ID（ANDROID_ID） |
| `ts` | 是 | 设备本地毫秒时间戳 |
| `ip` | 尽量 | 当前 IP；获取失败可 `""` 或省略 |
| `rustdeskId` | 尽量 | 有则带上，方便你直接发起连接 |
| `appVersion` | 建议 | APK 版本名 |
| `mainServiceRunning` | 建议 | 被控服务是否在跑 |
| `battery` / `charging` | 可选 | 老人机电量 |

监控端列表逻辑建议：收到心跳 → upsert；`now - ts > 30s` → 标离线。

---

## 6. Action 一览

### 6.1 基础运维

| action | 说明 |
|---|---|
| `ping` | 心跳探测（可广播） |
| `get_status` | 综合状态 |
| `revive` | 拉起 MainService + 看门狗 |
| `start_rustdesk` | `FFI.startService()` |
| `enable_watchdog` / `disable_watchdog` | 看门狗开关 |
| `reboot_app` | 重启 App 进程（尽力而为） |

#### `get_status` → `data` 示例

```json
{
  "deviceId": "a1b2c3...",
  "rustdeskId": "123456789",
  "ip": "192.168.1.23",
  "mainServiceRunning": true,
  "watchdogEnabled": true,
  "mqttConnected": true,
  "heartbeatEnabled": true,
  "mediaProjectionReady": false,
  "accessibilityEnabled": true,
  "overlayEnabled": true,
  "appVersion": "1.4.9",
  "settings": { "...见 6.4..." },
  "grants": [
    { "controllerId": "987654321", "expireAt": 1710007200000 }
  ]
}
```

---

### 6.2 版本与下载

#### A. 全局版本（推荐监控端直接读 retained）

订阅 / 读取：`rd/v1/sys/version`（retain）

```json
{
  "v": 1,
  "latestVersion": "1.4.10",
  "latestVersionCode": 68,
  "downloadUrl": "https://example.com/rustdesk-1.4.10.apk",
  "changelog": "保活与家庭监控增强",
  "forceUpdate": false,
  "minSupportedVersion": "1.4.0",
  "ts": 1710000000000
}
```

> 该消息由**你的发布流程 / 监控端**写入 Broker（retain）；设备与客户端都只读。

#### B. 设备查询并可选跳转下载

```json
{
  "v": 1,
  "requestId": "r1",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "get_update_info",
  "params": {
    "openBrowser": false
  }
}
```

| params | 默认 | 说明 |
|---|---|---|
| `openBrowser` | `false` | `true` 时设备用系统浏览器打开 `downloadUrl` |

回执 `data`：合并本地版本 + `sys/version` 内容 + `needUpdate: bool`。

```json
{
  "v": 1,
  "requestId": "r2",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "open_download",
  "params": {
    "url": "https://example.com/rustdesk-1.4.10.apk"
  }
}
```

`url` 可省略：省略则使用 `sys/version.downloadUrl`。

---

### 6.3 临时免密授权（核心）

家庭场景：你在监控端选「授权控制方 RustDesk ID」，设备在时效内对该 ID **自动接受连接，无需老人点确认、无需再输密码**。

```json
{
  "v": 1,
  "requestId": "grant-1",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "grant_access",
  "params": {
    "controllerId": "987654321",
    "ttlSec": 7200,
    "permissions": {
      "keyboard": true,
      "clipboard": true,
      "file": true,
      "audio": true,
      "camera": false,
      "terminal": false
    },
    "note": "儿子手机"
  }
}
```

| params | 必填 | 说明 |
|---|---|---|
| `controllerId` | 是 | 控制端 RustDesk ID（纯数字字符串） |
| `ttlSec` | 否 | 有效秒数；**默认 `7200`（2h）**；**最小 `60`**；**最大 `2592000`（30 天）** |
| `permissions` | 否 | 会话权限；缺省全开常用项（键盘/剪贴板/文件/音频） |
| `note` | 否 | 仅记录，便于列表展示 |

回执：

```json
{
  "ok": true,
  "code": 0,
  "deviceId": "a1b2c3d4e5f6g7h8",
  "data": {
    "controllerId": "987654321",
    "expireAt": 1710007200000,
    "ttlSec": 7200,
    "temporaryPassword": null
  }
}
```

说明：

- 优先走 **ID 白名单自动接听**（对名单内 ID 静默接受）。
- 若运行环境无法静默接（极端 ROM），回执可附带 `temporaryPassword` 作为降级；正常家庭机应 `temporaryPassword: null`。

撤销：

```json
{
  "action": "revoke_access",
  "requestId": "g2",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "params": { "controllerId": "987654321" }
}
```

清空全部临时授权：

```json
{
  "action": "revoke_all_access",
  "requestId": "g3",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "params": {}
}
```

查询：

```json
{
  "action": "list_grants",
  "requestId": "g4",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "params": {}
}
```

---

### 6.4 策略设置（家庭监控开关）

统一用 `set_policy` / `get_policy`。

#### 设置

```json
{
  "v": 1,
  "requestId": "p1",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "set_policy",
  "params": {
    "autoAcceptIncoming": true,
    "silentFileTransfer": true,
    "enableFileTransfer": true,
    "autoAnswerVoiceCall": true,
    "enableClipboard": true,
    "enableKeyboard": true,
    "enableAudio": true,
    "enableCamera": true,
    "enableRecordSession": true,
    "allowAutoRecordIncoming": true,
    "hideStopService": true,
    "denyLanDiscovery": false,
    "heartbeatEnabled": true
  }
}
```

只传要改的字段（部分更新）。设备合并后会把**完整策略**推给本机 Flutter，能力即时生效。

#### 开关语义（家庭监控默认建议）

| 字段 | 类型 | 默认建议 | 含义 |
|---|---|---|---|
| `heartbeatEnabled` | bool | **`true`** | 是否每 10 秒上报 `rd/v1/heartbeat` |
| `autoAcceptIncoming` | bool | `true` | **自动允许被控**（不弹「接受/拒绝」） |
| `silentFileTransfer` | bool | `true` | 文件传输静默允许，不弹确认 |
| `enableFileTransfer` | bool | `true` | 允许文件传输（与 `silentFileTransfer` 任一为真即开） |
| `autoAnswerVoiceCall` | bool | `true` | 语音通话自动接听 |
| `enableKeyboard` | bool | `true` | 允许远程键鼠 |
| `enableClipboard` | bool | `true` | 允许剪贴板 |
| `enableAudio` | bool | `true` | 允许音频 |
| `enableCamera` | bool | `true` | 允许摄像头 |
| `enableRecordSession` | bool | `true` | 允许会话录像 |
| `allowAutoRecordIncoming` | bool | `true` | 来连自动开始录像 |
| `hideStopService` | bool | `true` | 隐藏/禁用「停止服务」，防老人误触 |
| `denyLanDiscovery` | bool | `false` | 是否禁止局域网发现 |
| `requirePasswordForOthers` | bool | `true` | 非 grant 名单内的连接仍要密码（防陌生人） |

#### 查询

```json
{
  "action": "get_policy",
  "requestId": "p2",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "params": {}
}
```

回执 `data` 返回当前完整策略对象。

---

### 6.5 网络配置（ID 服务器 / Key / 中继）

主控端可远程改设备上的 RustDesk 网络参数（对应设置页「ID/中继服务器」）。

```json
{
  "v": 1,
  "requestId": "net1",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "set_network",
  "params": {
    "idServer": "hbbs.example.com",
    "key": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "relayServer": "",
    "apiServer": ""
  }
}
```

| params | 必填 | 说明 |
|---|---|---|
| `idServer` | 否* | ID 服务器（别名：`server` / `rendezvous`） |
| `key` | 否* | 公钥 / Key |
| `relayServer` | 否* | 中继服务器（别名：`relay`）；**可为空字符串**，表示不设自定义中继 |
| `apiServer` | 否 | API 服务器（别名：`api`） |

\* 至少提供上述字段之一。只传要改的字段；改完会重启 rendezvous 连接。  
`set_network` 为敏感操作，**必须**带明确 `deviceId`。

查询：

```json
{
  "action": "get_network",
  "requestId": "net2",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "params": {}
}
```

回执 `data` 示例：`{ "idServer", "relayServer", "apiServer", "key" }`。`get_status` 里也会带 `network` 字段。

---

### 6.6 服务与权限辅助

| action | 说明 |
|---|---|
| `open_accessibility_settings` | 跳转系统无障碍页（无法静默授予，只能引导） |
| `open_overlay_settings` | 跳转悬浮窗设置 |
| `request_media_projection` | 弹出录屏授权（系统强制，无法静默） |
| `notify` | 设备弹通知：`params.title` / `params.body` |

> **硬限制**：录屏（MediaProjection）、无障碍 **不能** 被 MQTT 静默授予。协议提供跳转/提醒；策略类开关可以静默改。

---

## 7. 监控端推荐用法

### 7.1 启动时

1. 连接 Broker（TLS 8883）。
2. 订阅固定 topic：
   - `rd/v1/heartbeat` ← **设备列表从这里来**
   - `rd/v1/ack`
   - `rd/v1/event`
   - `rd/v1/sys/version`
3. 用心跳 upsert 设备：显示备注、`deviceId`、`rustdeskId`、`ip`、最后在线时间。

### 7.2 「一键控制某台老人机」

1. 从心跳列表选设备 → 拿到 `deviceId`、`rustdeskId`。
2. 往 **`rd/v1/cmd`** 发 `grant_access`（参数里带该 `deviceId`），`controllerId = 自己的 RustDesk ID`，`ttlSec = 7200`。
3. 等 `rd/v1/ack` 且 `ok`。
4. 用 RustDesk 客户端连接 `rustdeskId`。
5. 结束时可 `revoke_access`。

### 7.3 「改策略 / 关心跳」

```json
{
  "v": 1,
  "requestId": "3",
  "deviceId": "从心跳抄来的ID",
  "action": "set_policy",
  "params": {
    "autoAcceptIncoming": true,
    "silentFileTransfer": true,
    "autoAnswerVoiceCall": true,
    "heartbeatEnabled": true
  }
}
```

### 7.4 「检查更新」

读 retained `rd/v1/sys/version`；要对某台设备打开浏览器下载则发 `open_download`（带 `deviceId`）。

---

## 8. 健壮性约定

| 项 | 约定 |
|---|---|
| QoS | cmd/ack/heartbeat = 1；version retain = true |
| 寻址 | 设备只处理 `deviceId` 等于自己或 `"*"` 的指令；敏感 action 拒绝 `"*"` |
| 去重 | 设备对 `requestId` 保留最近 200 条 / 10 分钟，重复回 `409` |
| 过期 | 超过 `expireAt` 回 `408`，不执行 |
| 限流 | 同设备执行 ≤ 2 条 cmd/秒；超出 `429` |
| 心跳 | 默认 10s；关闭后不再发；重连后立即补发 1 次 |
| 离线判定 | 监控端：>30s 无心跳视为离线（可配置） |
| 重连 | 设备 `automaticReconnect=true`；重连后重订 topic、立即心跳 |
| 时钟 | 以设备本地时间为准校验 `expireAt` |
| 失败可观测 | 所有失败必须 ack，并尽量 `event: permission_missing` |
| 授权过期 | 本地定时清理 grants；过期发 `grant_expired` |
| 进程复活 | 看门狗拉起 MainService 后自动重连 MQTT 并恢复心跳 |

---

## 9. 与「不要对端确认」的对照

| 能力 | 能否完全静默 | 做法 |
|---|---|---|
| 自动允许被控 | 能（策略） | `autoAcceptIncoming` + `grant_access` |
| 静默文件传输 | 能（策略） | `silentFileTransfer` / `enableFileTransfer` |
| 自动接听语音 | 能（策略） | `autoAnswerVoiceCall` |
| 会话录像 | 能（策略） | `enableRecordSession` + `allowAutoRecordIncoming` |
| 临时免密 | 能（授权名单） | `grant_access` |
| 录屏授权 | **不能** | `request_media_projection` / 首次人工点一次 |
| 无障碍 | **不能** | `open_accessibility_settings` / 首次人工开一次 |
| 厂商自启动白名单 | **不能** | 首次配置向导（另文） |

首次装机仍需一次人工：录屏 + 无障碍 +（建议）厂商自启动。之后日常由 MQTT + 授权名单完成控制。

---

## 10. 实现分期（设备端）

| 阶段 | 内容 |
|---|---|
| **P0** | 固定 topic、`deviceId` 在参数、`heartbeat` 10s、ping/status/revive、sys/version、open_download |
| **P1** | `set_policy`/`get_policy`（含 heartbeat 开关）、grant/revoke/list、自动接听与静默文件 |
| **P2** | 事件完善、去重限流、与设置页双向同步 |

---

## 11. 快速联调样例

### 11.1 先看有哪些设备

订阅：`rd/v1/heartbeat`  
大约每 10 秒会收到：

```json
{
  "v": 1,
  "deviceId": "a1b2c3d4e5f6g7h8",
  "rustdeskId": "123456789",
  "ts": 1710000000000,
  "ip": "192.168.1.23",
  "appVersion": "1.4.9",
  "mainServiceRunning": true
}
```

### 11.2 对某台设备 ping

Publish → `rd/v1/cmd`：

```json
{
  "v": 1,
  "requestId": "1",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "ping",
  "ts": 1710000000000
}
```

订阅 → `rd/v1/ack`：

```json
{
  "v": 1,
  "requestId": "1",
  "action": "ping",
  "ok": true,
  "code": 0,
  "message": "ok",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "ts": 1710000000050,
  "data": {}
}
```

### 11.3 授权 2 小时

```json
{
  "v": 1,
  "requestId": "2",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "grant_access",
  "params": { "controllerId": "你的RustDeskID", "ttlSec": 7200 }
}
```

### 11.4 开齐家庭策略（含心跳）

```json
{
  "v": 1,
  "requestId": "3",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "set_policy",
  "params": {
    "autoAcceptIncoming": true,
    "silentFileTransfer": true,
    "autoAnswerVoiceCall": true,
    "hideStopService": true,
    "heartbeatEnabled": true
  }
}
```

---

## 12. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| 1.0.0 | 2026-07-21 | 首版：topic 含 deviceId、授权、策略、版本下载 |
| 1.1.0 | 2026-07-21 | **Topic 全部固定**；`deviceId` 改到消息参数；新增 10s `heartbeat`（可关，默认开） |
| 1.2.0 | 2026-07-21 | 新增 `set_network`/`get_network`；`grant_access` 连接层静默接听 |

---

## 13. 设备端实现状态（Android）

| 能力 | 状态 | 代码 |
|---|---|---|
| 固定 topic `rd/v1/*` | ✅ | `RemoteMqttManager.kt` |
| 10s heartbeat + 开关 | ✅ | `FamilyMqttPolicy.heartbeatEnabled` |
| ping / get_status / revive / watchdog | ✅ | `RemoteMqttManager` |
| set_policy / get_policy | ✅ | `FamilyMqttPolicy` |
| grant / revoke / list | ✅ | 名单落盘 + 同步 Rust；连接层按 `controllerId` 静默接听 |
| set_network / get_network | ✅ | 改 ID 服务器 / key / 中继（中继可空） |
| get_update_info / open_download | ✅ | 依赖 retained `rd/v1/sys/version` |
| MQTT 保活进程 | ✅ | `MqttCommandService`（App 启动 / 开机即起） |

监控端联调：订阅 `rd/v1/heartbeat` → 抄 `deviceId` → 往 `rd/v1/cmd` 发指令 → 听 `rd/v1/ack`。

