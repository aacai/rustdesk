# 家庭监控 MQTT 协议（设备端 ↔ 监控端）

> 版本：`1.5.0`  
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
| 端口 | `8084`（WebSocket over TLS，路径 `/mqtt`） |
| 协议 | `wss://s5ebe39b.ala.cn-hangzhou.emqxsl.cn:8084/mqtt` |
| 用户名 | `xiangqi_player` |
| 密码 | `xiangqi2024` |
| CA | `emqxsl-ca.crt` |
| QoS | 指令 / 回执 / 心跳默认 **1** |
| KeepAlive | 60s |

> 设备端与监控端**共用同一组 Broker 参数**（同一 `wss` 地址、同一账号），仅 ClientId 前缀不同。

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

1. 监控端订阅固定 topic：`rd/v1/up`
2. 设备每 **10 秒**上报一次心跳（`type: heartbeat`，含 `deviceId`、`ts`、`ip`、`rustdeskId`…）
3. 你在 UI 里看到设备列表 → 选中某一台 → 发指令时把该 `deviceId` 填进参数

心跳可在设置 / `set_policy` 里关闭，**默认开启**。

---

## 4. Topic 规划（定稿：全部固定，不含 deviceId）

统一前缀：`rd/v1`

| Topic | 方向 | 说明 |
|---|---|---|
| `rd/v1/cmd` | 监控端 → 所有设备 | **唯一指令入口**；body 里带 `deviceId` 指定目标 |
| `rd/v1/up` | 设备 → 监控端 | **上行统一出口**；body 里 `type` 区分 ack / event / heartbeat |
| `rd/v1/sys/version` | 发布者 → 全体 | 最新 APK 版本与下载链接（**retained**） |

### 为什么这样定

- 你发指令永远 publish 到 **`rd/v1/cmd`**，不用拼 topic、不用记 ID 格式。
- 设备列表靠 **`rd/v1/up`**（`type: heartbeat`）自动冒出来；`deviceId` 从心跳里抄到指令参数即可。
- 所有设备都订 `rd/v1/cmd`，各自只处理 `deviceId` 匹配自己的消息；`deviceId` 为空或 `"*"` 表示广播（慎用）。

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
  "type": "ack",
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

### 5.3 主动事件（`rd/v1/up`，`type: event`）

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

### 5.4 心跳上报（`rd/v1/up`，`type: heartbeat`）— 发现设备用

- 周期：**默认每 10 秒** 发一次（MQTT 连上后立即先发 1 次），可在设置页调整（见 §6.2 A.2）
- QoS：1
- retain：**false**（靠周期刷新列表；超时 = `max(90s, 2.5 × hbIntervalSec)` 无心跳可视为离线）
- 开关：设置页 / `set_policy.heartbeatEnabled`，**默认 `true`**

```json
{
  "v": 1,
  "deviceId": "a1b2c3d4e5f6g7h8",
  "rustdeskId": "123456789",
  "ts": 1710000000000,
  "ip": "192.168.1.23",
  "appVersion": "1.4.9",
  "hbIntervalSec": 10,
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
| `hbIntervalSec` | 建议 | 当前心跳周期（秒）；监控端据此算离线超时 |
| `mainServiceRunning` | 建议 | 被控服务是否在跑 |
| `battery` / `charging` | 可选 | 老人机电量 |

监控端列表逻辑建议：收到心跳 → upsert；`now - ts > max(90s, 2.5 × hbIntervalSec)` → 标离线。

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
  "ts": 1710000000000,
  "not_equal_then_replace": true,
  "config": {
    "idServer": "id.example.com",
    "relayServer": "relay.example.com",
    "apiServer": "https://api.example.com",
    "key": "xxxxxxxxxxxxxxxx"
  }
}
```

> 该消息由**你的发布流程 / 监控端**写入 Broker（retain）；设备与客户端都只读。

#### A.1 远程配置强制下发（`not_equal_then_replace` + `config`）

当 `not_equal_then_replace == true` 且 `config` 非空时，设备会把 `config` 里**每个非空字段**与本地对应配置逐项对比，只要有一项不同就用远端值覆盖本地（`idServer`→`custom-rendezvous-server`、`relayServer`→`relay-server`、`apiServer`→`api-server`、`key`→`key`）。空字段忽略、不参与对比也不覆盖。

- 应用时**跳过服务器连通性校验**，即使目标服务器暂时离线也会写入。
- 写入顺序：先写 key / relay / api，最后写 `custom-rendezvous-server` 触发 `RendezvousMediator` 重启，确保新 key/relay 立即生效；若本次未改 id 但改了 key/relay，会对 `custom-rendezvous-server` 原值重写一次强制重启。

**检查时机（三处）**：
1. 设备在线时收到 / broker 推送 retained `sys/version` → 实时对比应用；
2. 打开「家庭监控」设置页时主动检查一次；
3. 周期定时器（默认一天一次，省电），到点做本地对比（防用户手动改回）。

**检查频率**：可在「家庭监控 → 策略设置 → 配置检查频率」设置（1 小时 / 6 小时 / 12 小时 / 1 天，默认 1 天），本地选项 `mqtt-config-check-interval-min`，改后立即生效。

#### A.2 心跳周期设置

心跳周期可在「家庭监控 → 策略设置 → 心跳周期」设置（10 秒 / 30 秒 / 1 分钟 / 5 分钟，默认 10 秒），本地选项 `mqtt-heartbeat-interval-sec`，改后立即重启心跳生效。心跳 payload 增加 `hbIntervalSec` 字段标示当前周期，**监控端判离线的超时应取 `max(90s, 2.5 × hbIntervalSec)`**，否则选大周期（如 5 分钟）会被误判离线。

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
        "ip": "123.45.67.89",
        "ttlSec": 7200,
        "note": "儿子手机"
      }
}
```

| params | 必填 | 说明 |
|---|---|---|
| `controllerId` | 是 | 控制端 RustDesk ID（纯数字字符串）；收到即对该 ID 免密授权 |
| `ip` | 否 | 控制端网络地址（可选，便于排查 / 局域网辅助）；不参与鉴权 |
| `ttlSec` | 否 | 有效秒数；**默认 `7200`（2h）**；**最小 `60`**；**最大 `2592000`（30 天）** |
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

- 收到 `controllerId` 即把该 ID 加入免密名单；该 ID 发起连接时设备**静默接受，无需老人点确认、无需密码**。
- 连接即全功能（键盘/剪贴板/文件/音频/摄像头等），不再定义任何细粒度权限。
- 回执 `temporaryPassword` 正常为 `null`（家庭机可静默接听）。

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
    "autoAnswerVoiceCall": true,
    "watchdogEnabled": true,
    "heartbeatEnabled": true
  }
}
```

只传要改的字段（部分更新）。设备合并后会把**完整策略**推给本机 Flutter，能力即时生效。

#### 开关语义

| 字段 | 类型 | 默认建议 | 含义 | 生效时机 |
|---|---|---|---|---|
| `heartbeatEnabled` | bool | **`true`** | 是否每 10 秒上报 `rd/v1/up`（`type: heartbeat`） | 立即 |
| `autoAcceptIncoming` | bool | `true` | **自动允许被控**（不弹「接受/拒绝」） | 下次连接 |
| `autoAnswerVoiceCall` | bool | `true` | 语音通话自动接听（master Android 默认弹确认） | 下次语音 |
| `watchdogEnabled` | bool | `true` | 启用服务保活（ServiceWatchdog） | 立即 |

> 设备端 `set_policy`/`get_policy` **仅识别以上 4 个字段**，其余字段会被忽略（历史协议中的 `silentFileTransfer`/`enableKeyboard`/`enableAudio` 等细粒度开关已在 1.3.1 精简移除）。

优先级：`autoAcceptIncoming > autoAnswerVoiceCall > 密码验证 > 弹窗确认`。

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

### 6.5 网络配置（ID/Relay 服务器 / Key / API）

支持通过 MQTT 远程修改设备的 RustDesk 服务器配置（等价于设置页「ID/Relay Server」），无需重新打包 APK。

统一用 `set_config` / `get_config`。**`set_config` 必须带明确 `deviceId`，禁止广播。**

#### 查询（get_config）

```json
{
  "v": 1,
  "requestId": "c1",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "get_config",
  "params": {}
}
```

回执 `data.config`：

```json
{
  "idServer": "rustdesk.example.com:21116",
  "relayServer": "rustdesk.example.com:21117",
  "apiServer": "https://rustdesk.example.com",
  "key": "公钥内容…"
}
```

#### 设置（set_config）

只传要改的字段（部分更新）。设备会先用 `mainTestIfValidServer` 校验 `idServer` / `relayServer` 可达性，`apiServer` 校验 `http(s)://` 前缀；校验失败整体不生效并回 `code: 400`。

```json
{
  "v": 1,
  "requestId": "c2",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "set_config",
  "params": {
    "idServer": "rustdesk.example.com:21116",
    "relayServer": "rustdesk.example.com:21117",
    "apiServer": "https://rustdesk.example.com",
    "key": "公钥内容…"
  }
}
```

| params | 说明 | 校验 |
|---|---|---|
| `idServer` | 对应 `custom-rendezvous-server`（ID/Relay 服务器） | `mainTestIfValidServer` 非空即通过 |
| `relayServer` | 对应 `relay-server` | 同上 |
| `apiServer` | 对应 `api-server` | 必须以 `http://` 或 `https://` 开头 |
| `key` | 对应 `key`（公钥） | 原样写入，不校验 |

回执 `data.config` 返回写入后的完整当前配置（与 `get_config` 一致）。

> 生效时机：配置写入本地选项后即持久化；运行中的 rendezvous 连接在下次（重）连接时读取新值（断网重连或进程重启后生效）。MQTT 连接本身不受影响（Broker 独立）。

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

1. 连接 Broker（`wss://...:8084/mqtt`）。
2. 订阅固定 topic：
   - `rd/v1/up` ← **设备列表从这里来**（按 `type` 区分 ack / event / heartbeat）
   - `rd/v1/sys/version`
3. 用心跳 upsert 设备：显示备注、`deviceId`、`rustdeskId`、`ip`、最后在线时间。

### 7.2 「一键控制某台老人机」

1. 从心跳列表选设备 → 拿到 `deviceId`、`rustdeskId`。
2. 往 **`rd/v1/cmd`** 发 `grant_access`（参数里带该 `deviceId`），`controllerId = 自己的 RustDesk ID`，`ttlSec = 7200`。
3. 等 `rd/v1/up`（`type: ack`）且 `ok`。
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
    "autoAnswerVoiceCall": true,
    "heartbeatEnabled": true
  }
}
```

### 7.4 「检查更新」

读 retained `rd/v1/sys/version`；要主动查询某台设备更新状态可发 `get_update_info`（带 `deviceId`）。

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
| 自动允许被控 | 能（策略） | `autoAcceptIncoming` |

| 临时免密 | 能（授权名单） | `grant_access` |
| 录屏授权 | **不能** | `request_media_projection` / 首次人工点一次 |
| 无障碍 | **不能** | `open_accessibility_settings` / 首次人工开一次 |
| 厂商自启动白名单 | **不能** | 首次配置向导（另文） |

首次装机仍需一次人工：录屏 + 无障碍 +（建议）厂商自启动。之后日常由 MQTT + 授权名单完成控制。

---

## 10. 快速联调样例

### 10.1 先看有哪些设备

订阅：`rd/v1/up`（`type: heartbeat`）  
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

### 10.2 对某台设备 ping

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

订阅 → `rd/v1/up`（`type: ack`）：

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

### 10.3 授权 2 小时

```json
{
  "v": 1,
  "requestId": "2",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "grant_access",
  "params": { "controllerId": "你的RustDeskID", "ttlSec": 7200 }
}
```

### 10.4 开齐家庭策略（含心跳）

```json
{
  "v": 1,
  "requestId": "3",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "set_policy",
  "params": {
    "autoAcceptIncoming": true,
    "autoAnswerVoiceCall": true,
    "heartbeatEnabled": true
  }
}
```

### 10.5 远程改 ID/Relay 服务器

```json
{
  "v": 1,
  "requestId": "4",
  "deviceId": "a1b2c3d4e5f6g7h8",
  "action": "set_config",
  "params": {
    "idServer": "rustdesk.example.com:21116",
    "relayServer": "rustdesk.example.com:21117",
    "apiServer": "https://rustdesk.example.com"
  }
}
```

成功回 `code: 0`，`data.config` 为写入后的完整配置；`idServer`/`relayServer` 不可达或 `apiServer` 前缀非法则回 `code: 400`，配置不生效。

---

## 11. 授权后不需要二次确认的功能

一旦 `autoAcceptIncoming` 授权通过，session 建立后以下功能可直接使用，不需要对端再次确认：

| 功能 | 说明 |
|---|---|
| 文件传输 | 同一 session 内自由读写文件 |
| 查看摄像头 | 实时查看设备摄像头 |
| 终端 | 远程命令行 |
| 端口转发 | 网络隧道 |
| 键鼠控制 | 远程输入 |
| 剪贴板 | 共享剪贴板 |
| 音频 | 远程音频 |
| 会话录像 | 录屏 |
| 自动录像 | 来连自动开始录像 |

这些功能在 `set_policy` 协议中不再保留独立开关。控制权仅通过连接授权管理：允许连接 = 允许所有功能。

**例外：** 语音通话（`autoAnswerVoiceCall`）在授权后仍需单独处理，因为语音是独立于 session 的 event，对端会弹「接听/拒绝」对话框。

