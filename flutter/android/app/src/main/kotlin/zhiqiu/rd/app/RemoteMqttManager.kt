package zhiqiu.rd.app

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import ffi.FFI
import org.eclipse.paho.client.mqttv3.IMqttDeliveryToken
import org.eclipse.paho.client.mqttv3.MqttCallbackExtended
import org.eclipse.paho.client.mqttv3.MqttClient
import org.eclipse.paho.client.mqttv3.MqttConnectOptions
import org.eclipse.paho.client.mqttv3.MqttMessage
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import org.json.JSONObject
import java.io.BufferedInputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.Collections
import java.util.LinkedHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import kotlin.concurrent.thread

data class MqttBrokerConfig(
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
    val caCertAsset: String,
    val keepAliveIntervalSec: Int,
)

/**
 * Family-monitor MQTT client (protocol docs/家庭监控-MQTT协议.md v1.1).
 * Fixed topics; deviceId is always in JSON body.
 */
object RemoteMqttManager {
    private val logTag = "RemoteMqtt"

    private const val DEFAULT_HOST = "s5ebe39b.ala.cn-hangzhou.emqxsl.cn"
    private const val DEFAULT_PORT = 8883
    private const val DEFAULT_USERNAME = "i2aea494"
    private const val DEFAULT_PASSWORD = "QzCV-8jJK5aR6gfY"
    private const val DEFAULT_CA = "emqxsl-ca.crt"

    const val TOPIC_CMD = "rd/v1/cmd"
    const val TOPIC_ACK = "rd/v1/ack"
    const val TOPIC_EVENT = "rd/v1/event"
    const val TOPIC_HEARTBEAT = "rd/v1/heartbeat"
    const val TOPIC_SYS_VERSION = "rd/v1/sys/version"

    private const val HEARTBEAT_INTERVAL_SEC = 10L
    private const val DEDUP_WINDOW_MS = 10 * 60 * 1000L
    private const val DEDUP_MAX = 200
    private const val RATE_LIMIT_PER_SEC = 2

    @Volatile private var client: MqttClient? = null
    @Volatile private var broker: MqttBrokerConfig? = null
    @Volatile private var deviceId: String = ""
    @Volatile private var cachedSysVersion: JSONObject? = null
    @Volatile private var appContext: Context? = null

    private val lock = Any()
    private val scheduler = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "mqtt-heartbeat").apply { isDaemon = true }
    }
    @Volatile private var heartbeatFuture: ScheduledFuture<*>? = null

    private val recentRequestIds =
        Collections.synchronizedMap(object : LinkedHashMap<String, Long>(DEDUP_MAX, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?): Boolean {
                return size > DEDUP_MAX
            }
        })
    private val rateWindowStart = AtomicInteger(0)
    private val rateCount = AtomicInteger(0)

    fun start(context: Context) {
        appContext = context.applicationContext
        // Keep Rust grant whitelist in sync even if MQTT was offline when grants changed
        FamilyMqttPolicy.syncGrantsToRust(context.applicationContext)
        thread(name = "mqtt-start", isDaemon = true) {
            synchronized(lock) {
                try {
                    ensureConnectedLocked(context.applicationContext)
                } catch (e: Exception) {
                    Log.e(logTag, "start failed", e)
                }
            }
        }
    }

    fun ensureConnected(context: Context) {
        start(context)
    }

    fun stop(context: Context) {
        synchronized(lock) {
            stopHeartbeat()
            try {
                client?.disconnect()
                client?.close()
            } catch (e: Exception) {
                Log.w(logTag, "stop", e)
            } finally {
                client = null
            }
        }
    }

    private fun ensureConnectedLocked(context: Context) {
        if (client?.isConnected == true) {
            restartHeartbeatIfNeeded(context)
            return
        }
        val cfg = loadBroker(context)
        broker = cfg
        deviceId = FamilyMqttPolicy.deviceId(context)
        val serverUri = "ssl://${cfg.host}:${cfg.port}"
        val clientId = "rd-dev-$deviceId-${System.currentTimeMillis() % 100000}"
        val mqttClient = MqttClient(serverUri, clientId, MemoryPersistence())
        val options = MqttConnectOptions().apply {
            isAutomaticReconnect = true
            isCleanSession = true
            connectionTimeout = 30
            keepAliveInterval = cfg.keepAliveIntervalSec
            userName = cfg.username
            password = cfg.password.toCharArray()
            socketFactory = buildSocketFactory(context, cfg.caCertAsset)
            // LWT optional: fixed topic with deviceId in body
            setWill(
                TOPIC_EVENT,
                JSONObject().apply {
                    put("v", 1)
                    put("event", "offline_hint")
                    put("deviceId", deviceId)
                    put("ts", System.currentTimeMillis())
                    put("data", JSONObject())
                }.toString().toByteArray(Charsets.UTF_8),
                1,
                false
            )
        }
        mqttClient.setCallback(object : MqttCallbackExtended {
            override fun connectComplete(reconnect: Boolean, serverURI: String?) {
                Log.i(logTag, "connected reconnect=$reconnect uri=$serverURI")
                try {
                    mqttClient.subscribe(TOPIC_CMD, 1)
                    mqttClient.subscribe(TOPIC_SYS_VERSION, 1)
                    Log.i(logTag, "subscribed $TOPIC_CMD , $TOPIC_SYS_VERSION")
                } catch (e: Exception) {
                    Log.e(logTag, "subscribe failed", e)
                }
                publishEvent(context, "online", JSONObject().apply {
                    put("event", if (reconnect) "reconnected" else "connected")
                })
                restartHeartbeatIfNeeded(context)
                publishHeartbeat(context)
            }

            override fun connectionLost(cause: Throwable?) {
                Log.w(logTag, "connection lost", cause)
                stopHeartbeat()
            }

            override fun messageArrived(topic: String?, message: MqttMessage?) {
                val payload = message?.payload?.toString(Charsets.UTF_8) ?: return
                when (topic) {
                    TOPIC_CMD -> handleCommand(context, payload)
                    TOPIC_SYS_VERSION -> {
                        try {
                            cachedSysVersion = JSONObject(payload)
                            Log.i(logTag, "sys/version cached")
                        } catch (e: Exception) {
                            Log.w(logTag, "bad sys/version", e)
                        }
                    }
                }
            }

            override fun deliveryComplete(token: IMqttDeliveryToken?) {}
        })
        mqttClient.connect(options)
        client = mqttClient
    }

    private fun restartHeartbeatIfNeeded(context: Context) {
        stopHeartbeat()
        if (!FamilyMqttPolicy.isHeartbeatEnabled(context)) {
            Log.d(logTag, "heartbeat disabled")
            return
        }
        heartbeatFuture = scheduler.scheduleAtFixedRate({
            try {
                if (!FamilyMqttPolicy.isHeartbeatEnabled(context)) {
                    stopHeartbeat()
                    return@scheduleAtFixedRate
                }
                publishHeartbeat(context)
            } catch (e: Exception) {
                Log.w(logTag, "heartbeat tick", e)
            }
        }, HEARTBEAT_INTERVAL_SEC, HEARTBEAT_INTERVAL_SEC, TimeUnit.SECONDS)
    }

    private fun stopHeartbeat() {
        heartbeatFuture?.cancel(false)
        heartbeatFuture = null
    }

    private fun handleCommand(context: Context, payload: String) {
        var requestId = ""
        var action = ""
        try {
            val json = JSONObject(payload)
            if (json.optInt("v", 1) != 1) {
                return
            }
            requestId = json.optString("requestId", "")
            action = json.optString("action", json.optString("cmd", "")).lowercase()
            val target = json.optString("deviceId", "")
            if (!isAddressedToMe(target)) {
                return
            }
            if (isSensitiveAction(action) && (target.isEmpty() || target == "*")) {
                publishAck(context, requestId, action, false, 400, "deviceId required", JSONObject())
                return
            }
            val expireAt = json.optLong("expireAt", 0)
            val ts = json.optLong("ts", 0)
            val effectiveExpire = when {
                expireAt > 0 -> expireAt
                ts > 0 -> ts + 120_000
                else -> 0
            }
            if (effectiveExpire > 0 && System.currentTimeMillis() > effectiveExpire) {
                publishAck(context, requestId, action, false, 408, "expired", JSONObject())
                return
            }
            if (requestId.isNotEmpty() && isDuplicate(requestId)) {
                publishAck(context, requestId, action, false, 409, "duplicate requestId", JSONObject())
                return
            }
            if (!allowRate()) {
                publishAck(context, requestId, action, false, 429, "rate limited", JSONObject())
                return
            }
            if (requestId.isNotEmpty()) {
                markHandled(requestId)
            }
            val params = json.optJSONObject("params") ?: JSONObject()
            dispatchAction(context, action, requestId, params)
        } catch (e: Exception) {
            Log.e(logTag, "handleCommand", e)
            publishAck(context, requestId, action.ifEmpty { "unknown" }, false, 500, e.message ?: "error", JSONObject())
        }
    }

    private fun isAddressedToMe(target: String): Boolean {
        if (target.isEmpty() || target == "*") return true
        return target == deviceId
    }

    private fun isSensitiveAction(action: String): Boolean {
        return action in setOf(
            "grant_access", "revoke_access", "revoke_all_access",
            "set_policy", "set_network", "open_download", "request_media_projection"
        )
    }

    private fun isDuplicate(requestId: String): Boolean {
        val now = System.currentTimeMillis()
        synchronized(recentRequestIds) {
            recentRequestIds.entries.removeAll { now - it.value > DEDUP_WINDOW_MS }
            return recentRequestIds.containsKey(requestId)
        }
    }

    private fun markHandled(requestId: String) {
        synchronized(recentRequestIds) {
            recentRequestIds[requestId] = System.currentTimeMillis()
        }
    }

    private fun allowRate(): Boolean {
        val sec = (System.currentTimeMillis() / 1000).toInt()
        val prev = rateWindowStart.get()
        if (prev != sec) {
            rateWindowStart.set(sec)
            rateCount.set(0)
        }
        return rateCount.incrementAndGet() <= RATE_LIMIT_PER_SEC
    }

    private fun dispatchAction(context: Context, action: String, requestId: String, params: JSONObject) {
        when (action) {
            "ping" -> publishAck(context, requestId, action, true, 0, "ok", JSONObject())

            "status", "get_status" ->
                publishAck(context, requestId, action, true, 0, "ok", buildStatusData(context))

            "start_service", "revive", "restart_service" -> {
                ServiceWatchdog.enable(context)
                MqttCommandService.start(context)
                val ok = ServiceWatchdog.reviveMainService(context.applicationContext)
                publishAck(context, requestId, action, ok, if (ok) 0 else 503, if (ok) "ok" else "revive failed", JSONObject().apply {
                    put("mainServiceRunning", ServiceWatchdog.isMainServiceRunning(context))
                })
            }

            "enable_watchdog" -> {
                ServiceWatchdog.enable(context)
                publishAck(context, requestId, action, true, 0, "ok", JSONObject().put("watchdog", true))
            }

            "disable_watchdog" -> {
                ServiceWatchdog.disable(context)
                publishAck(context, requestId, action, true, 0, "ok", JSONObject().put("watchdog", false))
            }

            "start_rustdesk" -> {
                try {
                    FFI.startService()
                    publishAck(context, requestId, action, true, 0, "ok", JSONObject().put("rustdesk", "started"))
                } catch (e: Exception) {
                    publishAck(context, requestId, action, false, 503, e.message ?: "FFI not ready", JSONObject())
                }
            }

            "get_policy" ->
                publishAck(context, requestId, action, true, 0, "ok", FamilyMqttPolicy.getPolicy(context))

            "set_policy" -> {
                val updated = FamilyMqttPolicy.setPolicy(context, params)
                if (params.has("heartbeatEnabled")) {
                    Handler(Looper.getMainLooper()).post {
                        synchronized(lock) {
                            restartHeartbeatIfNeeded(context)
                            if (FamilyMqttPolicy.isHeartbeatEnabled(context)) {
                                publishHeartbeat(context)
                            }
                        }
                    }
                }
                // Push full merged policy into Flutter so capabilities take effect live
                applyAutoAcceptHints(context)
                publishAck(context, requestId, action, true, 0, "ok", updated)
            }

            "get_network" ->
                publishAck(context, requestId, action, true, 0, "ok", readNetworkConfig())

            "set_network" -> {
                try {
                    val data = applyNetworkConfig(params)
                    publishAck(context, requestId, action, true, 0, "ok", data)
                } catch (e: Exception) {
                    publishAck(
                        context, requestId, action, false, 503,
                        e.message ?: "set_network failed", JSONObject()
                    )
                }
            }

            "grant_access" -> {
                val controllerId = params.optString("controllerId", "").trim()
                if (controllerId.isEmpty()) {
                    publishAck(context, requestId, action, false, 400, "controllerId required", JSONObject())
                    return
                }
                val ttl = if (params.has("ttlSec")) params.getInt("ttlSec") else FamilyMqttPolicy.TTL_DEFAULT_SEC
                val note = params.optString("note", "")
                val perms = params.optJSONObject("permissions")
                val grant = FamilyMqttPolicy.grantAccess(context, controllerId, ttl, note, perms)
                applyAutoAcceptHints(context)
                publishAck(context, requestId, action, true, 0, "ok", JSONObject().apply {
                    put("controllerId", grant.controllerId)
                    put("expireAt", grant.expireAt)
                    put("ttlSec", ((grant.expireAt - System.currentTimeMillis()) / 1000).coerceAtLeast(0))
                    put("temporaryPassword", JSONObject.NULL)
                })
            }

            "revoke_access" -> {
                val controllerId = params.optString("controllerId", "").trim()
                val removed = FamilyMqttPolicy.revokeAccess(context, controllerId)
                publishAck(context, requestId, action, true, 0, "ok", JSONObject().apply {
                    put("removed", removed)
                    put("controllerId", controllerId)
                })
            }

            "revoke_all_access" -> {
                FamilyMqttPolicy.revokeAll(context)
                publishAck(context, requestId, action, true, 0, "ok", JSONObject())
            }

            "list_grants" ->
                publishAck(context, requestId, action, true, 0, "ok", JSONObject().apply {
                    put("grants", FamilyMqttPolicy.grantsJson(context))
                })

            "get_update_info" -> {
                val ver = cachedSysVersion ?: JSONObject()
                val local = appVersionName(context)
                val latest = ver.optString("latestVersion", "")
                val needUpdate = latest.isNotEmpty() && latest != local
                if (params.optBoolean("openBrowser", false) && ver.has("downloadUrl")) {
                    openUrl(context, ver.optString("downloadUrl"))
                }
                publishAck(context, requestId, action, true, 0, "ok", JSONObject().apply {
                    put("appVersion", local)
                    put("needUpdate", needUpdate)
                    put("latest", ver)
                })
            }

            "open_download" -> {
                val url = params.optString("url").ifEmpty {
                    cachedSysVersion?.optString("downloadUrl").orEmpty()
                }
                if (url.isEmpty()) {
                    publishAck(context, requestId, action, false, 400, "no downloadUrl", JSONObject())
                    return
                }
                openUrl(context, url)
                publishAck(context, requestId, action, true, 0, "ok", JSONObject().put("url", url))
            }

            "open_accessibility_settings" -> {
                startAction(context, android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                publishAck(context, requestId, action, true, 0, "ok", JSONObject())
            }

            "open_overlay_settings" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    startAction(context, android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                }
                publishAck(context, requestId, action, true, 0, "ok", JSONObject())
            }

            "request_media_projection" -> {
                ServiceWatchdog.enable(context)
                ServiceWatchdog.reviveMainService(context.applicationContext)
                publishAck(context, requestId, action, true, 0, "ok", JSONObject().apply {
                    put("note", "started MainService; user may need to confirm screen capture")
                })
            }

            "notify" -> {
                val title = params.optString("title", "速远控")
                val body = params.optString("body", "")
                showNotify(context, title, body)
                publishAck(context, requestId, action, true, 0, "ok", JSONObject())
            }

            else -> publishAck(context, requestId, action, false, 404, "unknown action: $action", JSONObject())
        }
    }

    private fun applyAutoAcceptHints(context: Context) {
        val policy = FamilyMqttPolicy.getPolicy(context)
        // Persist flags for Flutter/Rust layers to pick up when available
        context.getSharedPreferences(KEY_SHARED_PREFERENCES, android.content.Context.MODE_PRIVATE)
            .edit()
            .putBoolean("KEY_FAMILY_AUTO_ACCEPT", policy.optBoolean("autoAcceptIncoming", true))
            .putBoolean("KEY_FAMILY_SILENT_FILE", policy.optBoolean("silentFileTransfer", true))
            .putBoolean("KEY_FAMILY_AUTO_VOICE", policy.optBoolean("autoAnswerVoiceCall", true))
            .apply()
        try {
            // Always push the full merged policy so Flutter can toggle live options
            MainActivity.flutterMethodChannel?.invokeMethod(
                "on_family_policy_changed",
                jsonObjectToMap(policy)
            )
        } catch (_: Exception) {
        }
    }

    private fun jsonObjectToMap(o: JSONObject): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val keys = o.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            val v = o.get(k)
            out[k] = when (v) {
                JSONObject.NULL -> null
                is JSONObject -> jsonObjectToMap(v)
                else -> v
            }
        }
        return out
    }

    /** Current ID / relay / key (relay may be empty). */
    private fun readNetworkConfig(): JSONObject {
        return try {
            JSONObject().apply {
                put("idServer", FFI.getOption("custom-rendezvous-server"))
                put("relayServer", FFI.getOption("relay-server"))
                put("apiServer", FFI.getOption("api-server"))
                put("key", FFI.getOption("key"))
            }
        } catch (e: Exception) {
            Log.w(logTag, "readNetworkConfig: ${e.message}")
            JSONObject()
        }
    }

    /**
     * Apply network options from MQTT.
     * Accepts aliases: idServer|server|rendezvous, relayServer|relay, apiServer|api, key.
     * Only provided keys are updated; relay may be explicitly set to "".
     */
    private fun applyNetworkConfig(params: JSONObject): JSONObject {
        fun firstString(vararg names: String): String? {
            for (n in names) {
                if (params.has(n) && params.get(n) !== JSONObject.NULL) {
                    return params.optString(n, "")
                }
            }
            return null
        }

        val idServer = firstString("idServer", "server", "rendezvous")
        val relayServer = firstString("relayServer", "relay")
        val apiServer = firstString("apiServer", "api")
        val key = firstString("key")

        if (idServer == null && relayServer == null && apiServer == null && key == null) {
            throw IllegalArgumentException("need idServer/key/relayServer (or aliases)")
        }

        try {
            if (idServer != null) {
                FFI.setOption("custom-rendezvous-server", idServer.trim())
            }
            if (relayServer != null) {
                // Empty string clears custom relay (allowed)
                FFI.setOption("relay-server", relayServer.trim())
            }
            if (apiServer != null) {
                FFI.setOption("api-server", apiServer.trim())
            }
            if (key != null) {
                FFI.setOption("key", key.trim())
            }
        } catch (e: UnsatisfiedLinkError) {
            throw IllegalStateException("FFI not ready", e)
        }

        val applied = readNetworkConfig()
        try {
            MainActivity.flutterMethodChannel?.invokeMethod(
                "on_family_network_changed",
                jsonObjectToMap(applied)
            )
        } catch (_: Exception) {
        }
        return applied
    }

    private fun buildStatusData(context: Context): JSONObject {
        return JSONObject().apply {
            put("deviceId", deviceId)
            put("rustdeskId", rustdeskId())
            put("ip", localIp(context))
            put("mainServiceRunning", ServiceWatchdog.isMainServiceRunning(context))
            put("watchdogEnabled", ServiceWatchdog.isEnabled(context))
            put("mqttConnected", client?.isConnected == true)
            put("heartbeatEnabled", FamilyMqttPolicy.isHeartbeatEnabled(context))
            put("mediaProjectionReady", MainService.isReady)
            put("accessibilityEnabled", InputService.isOpen)
            put(
                "overlayEnabled",
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    android.provider.Settings.canDrawOverlays(context)
                } else {
                    true
                }
            )
            put("appVersion", appVersionName(context))
            put("settings", FamilyMqttPolicy.getPolicy(context))
            put("grants", FamilyMqttPolicy.grantsJson(context))
            put("network", readNetworkConfig())
        }
    }

    private fun publishHeartbeat(context: Context) {
        thread(name = "mqtt-hb", isDaemon = true) {
            synchronized(lock) {
                try {
                    val c = client ?: return@synchronized
                    if (!c.isConnected) return@synchronized
                    if (!FamilyMqttPolicy.isHeartbeatEnabled(context)) return@synchronized
                    val battery = readBattery(context)
                    val payload = JSONObject().apply {
                        put("v", 1)
                        put("deviceId", deviceId.ifEmpty { FamilyMqttPolicy.deviceId(context) })
                        put("rustdeskId", rustdeskId())
                        put("ts", System.currentTimeMillis())
                        put("ip", localIp(context))
                        put("appVersion", appVersionName(context))
                        put("mainServiceRunning", ServiceWatchdog.isMainServiceRunning(context))
                        put("battery", battery.first)
                        put("charging", battery.second)
                    }.toString()
                    c.publish(TOPIC_HEARTBEAT, MqttMessage(payload.toByteArray(Charsets.UTF_8)).apply {
                        qos = 1
                        isRetained = false
                    })
                } catch (e: Exception) {
                    Log.w(logTag, "publishHeartbeat", e)
                }
            }
        }
    }

    private fun publishAck(
        context: Context,
        requestId: String,
        action: String,
        ok: Boolean,
        code: Int,
        message: String,
        data: JSONObject,
    ) {
        thread(name = "mqtt-ack", isDaemon = true) {
            synchronized(lock) {
                try {
                    ensureConnectedLocked(context.applicationContext)
                    val c = client ?: return@synchronized
                    val payload = JSONObject().apply {
                        put("v", 1)
                        put("requestId", requestId)
                        put("action", action)
                        put("ok", ok)
                        put("code", code)
                        put("message", message)
                        put("deviceId", deviceId)
                        put("ts", System.currentTimeMillis())
                        put("data", data)
                    }.toString()
                    c.publish(TOPIC_ACK, MqttMessage(payload.toByteArray(Charsets.UTF_8)).apply {
                        qos = 1
                        isRetained = false
                    })
                } catch (e: Exception) {
                    Log.e(logTag, "publishAck", e)
                }
            }
        }
    }

    private fun publishEvent(context: Context, event: String, data: JSONObject) {
        thread(name = "mqtt-event", isDaemon = true) {
            synchronized(lock) {
                try {
                    val c = client ?: return@synchronized
                    if (!c.isConnected) return@synchronized
                    val payload = JSONObject().apply {
                        put("v", 1)
                        put("event", event)
                        put("deviceId", deviceId)
                        put("ts", System.currentTimeMillis())
                        put("data", data)
                    }.toString()
                    c.publish(TOPIC_EVENT, MqttMessage(payload.toByteArray(Charsets.UTF_8)).apply {
                        qos = 1
                        isRetained = false
                    })
                } catch (e: Exception) {
                    Log.w(logTag, "publishEvent", e)
                }
            }
        }
    }

    private fun loadBroker(context: Context): MqttBrokerConfig {
        return try {
            context.assets.open("mqtt_config.json").use { input ->
                val json = JSONObject(input.bufferedReader().readText())
                MqttBrokerConfig(
                    host = json.optString("host").ifEmpty { DEFAULT_HOST },
                    port = json.optInt("port", DEFAULT_PORT),
                    username = json.optString("username").ifEmpty { DEFAULT_USERNAME },
                    password = json.optString("password").ifEmpty { DEFAULT_PASSWORD },
                    caCertAsset = json.optString("caCertAsset").ifEmpty { DEFAULT_CA },
                    keepAliveIntervalSec = json.optInt("keepAliveIntervalSec", 60),
                )
            }
        } catch (e: Exception) {
            Log.w(logTag, "mqtt_config.json missing, use built-in", e)
            MqttBrokerConfig(
                DEFAULT_HOST, DEFAULT_PORT, DEFAULT_USERNAME, DEFAULT_PASSWORD, DEFAULT_CA, 60
            )
        }
    }

    private fun rustdeskId(): String {
        return try {
            FFI.getLocalOption("id").ifEmpty { "" }
        } catch (_: Exception) {
            ""
        }
    }

    private fun appVersionName(context: Context): String {
        return try {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    private fun localIp(context: Context): String {
        try {
            val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val net = cm?.activeNetwork
                val link = cm?.getLinkProperties(net)
                link?.linkAddresses?.forEach { la ->
                    val addr = la.address
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        return addr.hostAddress ?: ""
                    }
                }
            }
            @Suppress("DEPRECATION")
            val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            @Suppress("DEPRECATION")
            val ipInt = wm?.connectionInfo?.ipAddress ?: 0
            if (ipInt != 0) {
                return String.format(
                    "%d.%d.%d.%d",
                    ipInt and 0xff,
                    ipInt shr 8 and 0xff,
                    ipInt shr 16 and 0xff,
                    ipInt shr 24 and 0xff
                )
            }
            val en = NetworkInterface.getNetworkInterfaces()
            while (en.hasMoreElements()) {
                val intf = en.nextElement()
                val addrs = intf.inetAddresses
                while (addrs.hasMoreElements()) {
                    val addr = addrs.nextElement()
                    if (!addr.isLoopbackAddress && addr is Inet4Address) {
                        return addr.hostAddress ?: ""
                    }
                }
            }
        } catch (_: Exception) {
        }
        return ""
    }

    private fun readBattery(context: Context): Pair<Int, Boolean> {
        return try {
            val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val pct = if (level >= 0 && scale > 0) (level * 100 / scale) else -1
            val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL
            Pair(pct, charging)
        } catch (_: Exception) {
            Pair(-1, false)
        }
    }

    private fun openUrl(context: Context, url: String) {
        Handler(Looper.getMainLooper()).post {
            try {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
            } catch (e: Exception) {
                Log.e(logTag, "openUrl", e)
            }
        }
    }

    private fun showNotify(context: Context, title: String, body: String) {
        Handler(Looper.getMainLooper()).post {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
                val channelId = "RustDeskMqttCmd"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    nm.createNotificationChannel(
                        android.app.NotificationChannel(
                            channelId, "远程指令", android.app.NotificationManager.IMPORTANCE_DEFAULT
                        )
                    )
                }
                val n = androidx.core.app.NotificationCompat.Builder(context, channelId)
                    .setSmallIcon(R.mipmap.ic_stat_logo)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setAutoCancel(true)
                    .build()
                nm.notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), n)
            } catch (e: Exception) {
                Log.e(logTag, "showNotify", e)
            }
        }
    }

    private fun buildSocketFactory(context: Context, caAsset: String): javax.net.ssl.SSLSocketFactory {
        val cf = CertificateFactory.getInstance("X.509")
        val caInput = BufferedInputStream(context.assets.open(caAsset))
        val ca = caInput.use { cf.generateCertificate(it) }
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry("ca", ca)
        }
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {
            init(keyStore)
        }
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(null, tmf.trustManagers, null)
        return sslContext.socketFactory
    }
}
