package com.carriez.flutter_hbbx

import android.content.Context
import android.provider.Settings
import android.util.Log
import ffi.FFI
import io.flutter.embedding.android.FlutterActivity
import org.json.JSONArray
import org.json.JSONObject

/** Local policy + temporary access grants for family-monitor MQTT protocol. */
object FamilyMqttPolicy {
    private const val TAG = "FamilyMqttPolicy"
    private const val PREFS = KEY_SHARED_PREFERENCES
    private const val KEY_POLICY = "KEY_FAMILY_MQTT_POLICY"
    private const val KEY_GRANTS = "KEY_FAMILY_MQTT_GRANTS"
    /** Synced into Rust LocalConfig for connection-layer silent accept. */
    const val RUST_GRANTS_OPTION = "family-mqtt-grants"

    const val TTL_DEFAULT_SEC = 7200
    const val TTL_MIN_SEC = 60
    const val TTL_MAX_SEC = 2_592_000 // 30 days

    data class Grant(
        val controllerId: String,
        val expireAt: Long,
        val note: String = "",
        val permissions: JSONObject = JSONObject(),
    )

    fun deviceId(context: Context): String {
        return Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
            ?: "unknown"
    }

    fun getPolicy(context: Context): JSONObject {
        val prefs = context.getSharedPreferences(PREFS, FlutterActivity.MODE_PRIVATE)
        val raw = prefs.getString(KEY_POLICY, null)
        val defaults = defaultPolicy()
        if (raw.isNullOrEmpty()) {
            return defaults
        }
        return try {
            val stored = JSONObject(raw)
            val keys = defaults.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                if (!stored.has(k)) {
                    stored.put(k, defaults.get(k))
                }
            }
            stored
        } catch (_: Exception) {
            defaults
        }
    }

    fun setPolicy(context: Context, patch: JSONObject): JSONObject {
        val cur = getPolicy(context)
        val keys = patch.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            cur.put(k, patch.get(k))
        }
        context.getSharedPreferences(PREFS, FlutterActivity.MODE_PRIVATE)
            .edit()
            .putString(KEY_POLICY, cur.toString())
            .apply()
        return cur
    }

    fun isHeartbeatEnabled(context: Context): Boolean {
        return getPolicy(context).optBoolean("heartbeatEnabled", true)
    }

    fun grantAccess(
        context: Context,
        controllerId: String,
        ttlSec: Int,
        note: String,
        permissions: JSONObject?,
    ): Grant {
        val ttl = ttlSec.coerceIn(TTL_MIN_SEC, TTL_MAX_SEC)
        val expireAt = System.currentTimeMillis() + ttl * 1000L
        val grant = Grant(
            controllerId = controllerId.trim(),
            expireAt = expireAt,
            note = note,
            permissions = permissions ?: defaultPermissions(),
        )
        val list = listGrants(context).filter { it.controllerId != grant.controllerId }.toMutableList()
        list.add(grant)
        saveGrants(context, list)
        syncGrantsToRust(context)
        return grant
    }

    fun revokeAccess(context: Context, controllerId: String): Boolean {
        val before = listGrants(context)
        val after = before.filter { it.controllerId != controllerId.trim() }
        saveGrants(context, after)
        syncGrantsToRust(context)
        return after.size != before.size
    }

    fun revokeAll(context: Context) {
        saveGrants(context, emptyList())
        syncGrantsToRust(context)
    }

    /** Push grant list into Rust so connection.rs can silent-accept by controllerId. */
    fun syncGrantsToRust(context: Context) {
        try {
            purgeExpired(context)
            FFI.setLocalOption(RUST_GRANTS_OPTION, grantsJson(context).toString())
        } catch (e: Exception) {
            Log.w(TAG, "syncGrantsToRust: ${e.message}")
        }
    }

    fun listGrants(context: Context): List<Grant> {
        purgeExpired(context)
        val prefs = context.getSharedPreferences(PREFS, FlutterActivity.MODE_PRIVATE)
        val raw = prefs.getString(KEY_GRANTS, "[]") ?: "[]"
        return try {
            val arr = JSONArray(raw)
            val out = mutableListOf<Grant>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                out.add(
                    Grant(
                        controllerId = o.getString("controllerId"),
                        expireAt = o.getLong("expireAt"),
                        note = o.optString("note", ""),
                        permissions = o.optJSONObject("permissions") ?: defaultPermissions(),
                    )
                )
            }
            out
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun isControllerGranted(context: Context, controllerId: String): Boolean {
        val now = System.currentTimeMillis()
        return listGrants(context).any {
            it.controllerId == controllerId.trim() && it.expireAt > now
        }
    }

    fun grantsJson(context: Context): JSONArray {
        val arr = JSONArray()
        for (g in listGrants(context)) {
            arr.put(
                JSONObject().apply {
                    put("controllerId", g.controllerId)
                    put("expireAt", g.expireAt)
                    put("note", g.note)
                    put("permissions", g.permissions)
                }
            )
        }
        return arr
    }

    private fun purgeExpired(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, FlutterActivity.MODE_PRIVATE)
        val raw = prefs.getString(KEY_GRANTS, "[]") ?: "[]"
        try {
            val arr = JSONArray(raw)
            val now = System.currentTimeMillis()
            val kept = JSONArray()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                if (o.optLong("expireAt", 0) > now) {
                    kept.put(o)
                }
            }
            if (kept.length() != arr.length()) {
                prefs.edit().putString(KEY_GRANTS, kept.toString()).apply()
            }
        } catch (_: Exception) {
        }
    }

    private fun saveGrants(context: Context, grants: List<Grant>) {
        val arr = JSONArray()
        for (g in grants) {
            arr.put(
                JSONObject().apply {
                    put("controllerId", g.controllerId)
                    put("expireAt", g.expireAt)
                    put("note", g.note)
                    put("permissions", g.permissions)
                }
            )
        }
        context.getSharedPreferences(PREFS, FlutterActivity.MODE_PRIVATE)
            .edit()
            .putString(KEY_GRANTS, arr.toString())
            .apply()
    }

    private fun defaultPolicy(): JSONObject {
        return JSONObject().apply {
            put("heartbeatEnabled", true)
            put("autoAcceptIncoming", true)
            put("silentFileTransfer", true)
            put("enableFileTransfer", true)
            put("autoAnswerVoiceCall", true)
            put("enableKeyboard", true)
            put("enableClipboard", true)
            put("enableAudio", true)
            put("enableCamera", true)
            put("enableRecordSession", true)
            put("allowAutoRecordIncoming", true)
            put("hideStopService", true)
            put("denyLanDiscovery", false)
            put("requirePasswordForOthers", true)
        }
    }

    private fun defaultPermissions(): JSONObject {
        return JSONObject().apply {
            put("keyboard", true)
            put("clipboard", true)
            put("file", true)
            put("audio", true)
            put("camera", false)
            put("terminal", false)
        }
    }
}
