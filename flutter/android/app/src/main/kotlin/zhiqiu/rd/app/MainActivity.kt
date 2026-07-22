package zhiqiu.rd.app

/**
 * Handle events from flutter
 * Request MediaProjection permission
 *
 * Inspired by [droidVNC-NG] https://github.com/bk138/droidVNC-NG
 */

import ffi.FFI

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.ClipboardManager
import android.os.Bundle
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.os.IBinder
import android.util.Log
import android.view.WindowManager
import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
import android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.DisplayMetrics
import androidx.annotation.RequiresApi
import org.json.JSONArray
import org.json.JSONObject
import com.hjq.permissions.XXPermissions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread
import java.io.File


class MainActivity : FlutterActivity() {
    companion object {
        var flutterMethodChannel: MethodChannel? = null
        private var _rdClipboardManager: RdClipboardManager? = null
        val rdClipboardManager: RdClipboardManager?
            get() = _rdClipboardManager;
    }

    private val channelTag = "mChannel"
    private val logTag = "mMainActivity"
    private var mainService: MainService? = null

    private var isAudioStart = false
    private val audioRecordHandle = AudioRecordHandle(this, { false }, { isAudioStart })

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (MainService.isReady) {
            Intent(activity, MainService::class.java).also {
                bindService(it, serviceConnection, Context.BIND_AUTO_CREATE)
            }
        }
        flutterMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelTag
        )
        initFlutterChannel(flutterMethodChannel!!)
        thread {
            try {
                setCodecInfo()
            } catch (e: Exception) {
                Log.e("MainActivity", "Failed to setCodecInfo: ${e.message}", e)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        val inputPer = InputService.isOpen
        activity.runOnUiThread {
            flutterMethodChannel?.invokeMethod(
                "on_state_changed",
                mapOf("name" to "input", "value" to inputPer.toString())
            )
        }
    }

    private fun requestMediaProjection() {
        val intent = Intent(this, PermissionRequestTransparentActivity::class.java).apply {
            action = ACT_REQUEST_MEDIA_PROJECTION
        }
        startActivityForResult(intent, REQ_INVOKE_PERMISSION_ACTIVITY_MEDIA_PROJECTION)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_INVOKE_PERMISSION_ACTIVITY_MEDIA_PROJECTION && resultCode == RES_FAILED) {
            flutterMethodChannel?.invokeMethod("on_media_projection_canceled", null)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (_rdClipboardManager == null) {
            _rdClipboardManager = RdClipboardManager(getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
            FFI.setClipboardManager(_rdClipboardManager!!)
        }
    }

    override fun onDestroy() {
        Log.e(logTag, "onDestroy")
        mainService?.let {
            unbindService(serviceConnection)
        }
        super.onDestroy()
    }

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            Log.d(logTag, "onServiceConnected")
            val binder = service as MainService.LocalBinder
            mainService = binder.getService()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            Log.d(logTag, "onServiceDisconnected")
            mainService = null
        }
    }

    private fun initFlutterChannel(flutterMethodChannel: MethodChannel) {
        flutterMethodChannel.setMethodCallHandler { call, result ->
            // make sure result will be invoked, otherwise flutter will await forever
            when (call.method) {
                "init_service" -> {
                    Intent(activity, MainService::class.java).also {
                        bindService(it, serviceConnection, Context.BIND_AUTO_CREATE)
                    }
                    if (MainService.isReady) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    requestMediaProjection()
                    result.success(true)
                }
                "start_capture" -> {
                    mainService?.let {
                        result.success(it.startCapture())
                    } ?: let {
                        result.success(false)
                    }
                }
                "stop_service" -> {
                    Log.d(logTag, "Stop service")
                    mainService?.let {
                        it.destroy()
                        result.success(true)
                    } ?: let {
                        result.success(false)
                    }
                }
                "check_permission" -> {
                    if (call.arguments is String) {
                        result.success(XXPermissions.isGranted(context, call.arguments as String))
                    } else {
                        result.success(false)
                    }
                }
                "request_permission" -> {
                    if (call.arguments is String) {
                        requestPermission(context, call.arguments as String)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                START_ACTION -> {
                    if (call.arguments is String) {
                        startAction(context, call.arguments as String)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "check_video_permission" -> {
                    mainService?.let {
                        result.success(it.checkMediaPermission())
                    } ?: let {
                        result.success(false)
                    }
                }
                "check_service" -> {
                    Companion.flutterMethodChannel?.invokeMethod(
                        "on_state_changed",
                        mapOf("name" to "input", "value" to InputService.isOpen.toString())
                    )
                    Companion.flutterMethodChannel?.invokeMethod(
                        "on_state_changed",
                        mapOf("name" to "media", "value" to MainService.isReady.toString())
                    )
                    result.success(true)
                }
                "stop_input" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        InputService.ctx?.disableSelf()
                    } else {
                        InputService.ctx = null
                        Companion.flutterMethodChannel?.invokeMethod(
                            "on_state_changed",
                            mapOf("name" to "input", "value" to InputService.isOpen.toString())
                        )
                    }
                    result.success(true)
                }
                "cancel_notification" -> {
                    if (call.arguments is Int) {
                        val id = call.arguments as Int
                        mainService?.cancelNotification(id)
                    } else {
                        result.success(true)
                    }
                }
                "enable_soft_keyboard" -> {
                    // https://blog.csdn.net/hanye2020/article/details/105553780
                    if (call.arguments as Boolean) {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
                    } else {
                        window.addFlags(WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM)
                    }
                    result.success(true)

                }
                "try_sync_clipboard" -> {
                    rdClipboardManager?.syncClipboard(true)
                    result.success(true)
                }
                GET_START_ON_BOOT_OPT -> {
                    val prefs = getSharedPreferences(KEY_SHARED_PREFERENCES, MODE_PRIVATE)
                    result.success(prefs.getBoolean(KEY_START_ON_BOOT_OPT, false))
                }
                SET_START_ON_BOOT_OPT -> {
                    if (call.arguments is Boolean) {
                        val prefs = getSharedPreferences(KEY_SHARED_PREFERENCES, MODE_PRIVATE)
                        val edit = prefs.edit()
                        edit.putBoolean(KEY_START_ON_BOOT_OPT, call.arguments as Boolean)
                        edit.apply()
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                SYNC_APP_DIR_CONFIG_PATH -> {
                    if (call.arguments is String) {
                        val prefs = getSharedPreferences(KEY_SHARED_PREFERENCES, MODE_PRIVATE)
                        val edit = prefs.edit()
                        edit.putString(KEY_APP_DIR_CONFIG_PATH, call.arguments as String)
                        edit.apply()
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                GET_VALUE -> {
                    if (call.arguments is String) {
                        if (call.arguments == KEY_IS_SUPPORT_VOICE_CALL) {
                            result.success(isSupportVoiceCall())
                        } else {
                            result.error("-1", "No such key", null)
                        }
                    } else {
                        result.success(null)
                    }
                }
                SET_FAMILY_POLICY -> {
                    try {
                        val json = call.arguments as? String
                        if (json != null) {
                            val policy = org.json.JSONObject(json)
                            // Watchdog enable/disable
                            if (policy.has("watchdogEnabled")) {
                                if (policy.getBoolean("watchdogEnabled")) {
                                    ServiceWatchdog.enable(context)
                                } else {
                                    ServiceWatchdog.disable(context)
                                }
                            }
                            // Persist all family-policy keys to SharedPreferences
                            val prefs = context.getSharedPreferences(KEY_SHARED_PREFERENCES, Context.MODE_PRIVATE)
                            val edit = prefs.edit()
                            for (key in policy.keys()) {
                                val raw = policy.get(key)
                                if (raw is Boolean) {
                                    edit.putBoolean("family_$key", raw)
                                }
                            }
                            edit.apply()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        Log.w(logTag, "set_family_policy error", e)
                        result.success(false)
                    }
                }
                "on_voice_call_started" -> {
                    onVoiceCallStarted()
                }
                "on_voice_call_closed" -> {
                    onVoiceCallClosed()
                }
                "start_mqtt_foreground" -> {
                    MqttForegroundService.start(context)
                    result.success(true)
                }
                "stop_mqtt_foreground" -> {
                    MqttForegroundService.stop(context)
                    result.success(true)
                }
                "is_battery_optimization_ignored" -> {
                    val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        result.success(pm.isIgnoringBatteryOptimizations(context.packageName))
                    } else {
                        result.success(true)
                    }
                }
                "request_battery_optimization" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                data = Uri.parse("package:${context.packageName}")
                            }
                            context.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.success(true)
                    }
                }
                "check_and_reconnect_mqtt" -> {
                    // Call Flutter to trigger MQTT reconnect check
                    flutterMethodChannel?.invokeMethod("check_mqtt_reconnect", null)
                    result.success(true)
                }
                "update_mqtt_status" -> {
                    val connected = call.argument<Boolean>("connected") ?: false
                    InputService.updateMqttStatus(connected)
                    result.success(true)
                }
                "start_black_screen" -> {
                    val started = BlackScreenService.start(applicationContext)
                    result.success(started)
                }
                "stop_black_screen" -> {
                    BlackScreenService.stop(applicationContext)
                    result.success(true)
                }
                "is_black_screen_running" -> {
                    result.success(BlackScreenService.isRunning)
                }
                "enable_zero_brightness" -> {
                    val success = BrightnessController.enable(applicationContext)
                    result.success(success)
                }
                "disable_zero_brightness" -> {
                    BrightnessController.disable(applicationContext)
                    result.success(true)
                }
                "is_zero_brightness_active" -> {
                    result.success(BrightnessController.isActive())
                }
                "is_shizuku_installed" -> {
                    result.success(ShizukuHelper.isShizukuInstalled(applicationContext))
                }
                "shizuku_screen_off" -> {
                    val success = ShizukuHelper.screenOff(applicationContext)
                    result.success(success)
                }
                "shizuku_screen_on" -> {
                    val success = ShizukuHelper.screenOn(applicationContext)
                    result.success(success)
                }
                "copy_display_toggle_dex" -> {
                    val success = copyDisplayToggleDex()
                    result.success(success)
                }
                else -> {
                    result.error("-1", "No such method", null)
                }
            }
        }
    }

    private fun setCodecInfo() {
        val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        val codecs = codecList.codecInfos
        val codecArray = JSONArray()

        val windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val wh = getScreenSize(windowManager)
        var w = wh.first
        var h = wh.second
        val align = 64
        w = (w + align - 1) / align * align
        h = (h + align - 1) / align * align
        codecs.forEach { codec ->
            val codecObject = JSONObject()
            codecObject.put("name", codec.name)
            codecObject.put("is_encoder", codec.isEncoder)
            var hw: Boolean? = null;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                hw = codec.isHardwareAccelerated
            } else {
                // https://chromium.googlesource.com/external/webrtc/+/HEAD/sdk/android/src/java/org/webrtc/MediaCodecUtils.java#29
                // https://chromium.googlesource.com/external/webrtc/+/master/sdk/android/api/org/webrtc/HardwareVideoEncoderFactory.java#229
                if (listOf("OMX.google.", "OMX.SEC.", "c2.android").any { codec.name.startsWith(it, true) }) {
                    hw = false
                } else if (listOf("c2.qti", "OMX.qcom.video", "OMX.Exynos", "OMX.hisi", "OMX.MTK", "OMX.Intel", "OMX.Nvidia").any { codec.name.startsWith(it, true) }) {
                    hw = true
                }
            }
            if (hw != true) {
                return@forEach
            }
            codecObject.put("hw", hw)
            var mime_type = ""
            codec.supportedTypes.forEach { type ->
                if (listOf("video/avc", "video/hevc").contains(type)) { // "video/x-vnd.on2.vp8", "video/x-vnd.on2.vp9", "video/av01"
                    mime_type = type;
                }
            }
            if (mime_type.isNotEmpty()) {
                codecObject.put("mime_type", mime_type)
                val caps = codec.getCapabilitiesForType(mime_type)
                if (codec.isEncoder) {
                    // Encoder's max_height and max_width are interchangeable
                    if (!caps.videoCapabilities.isSizeSupported(w,h) && !caps.videoCapabilities.isSizeSupported(h,w)) {
                        return@forEach
                    }
                }
                codecObject.put("min_width", caps.videoCapabilities.supportedWidths.lower)
                codecObject.put("max_width", caps.videoCapabilities.supportedWidths.upper)
                codecObject.put("min_height", caps.videoCapabilities.supportedHeights.lower)
                codecObject.put("max_height", caps.videoCapabilities.supportedHeights.upper)
                val surface = caps.colorFormats.contains(COLOR_FormatSurface);
                codecObject.put("surface", surface)
                val nv12 = caps.colorFormats.contains(COLOR_FormatYUV420SemiPlanar)
                codecObject.put("nv12", nv12)
                if (!(nv12 || surface)) {
                    return@forEach
                }
                codecObject.put("min_bitrate", caps.videoCapabilities.bitrateRange.lower / 1000)
                codecObject.put("max_bitrate", caps.videoCapabilities.bitrateRange.upper / 1000)
                if (!codec.isEncoder) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        codecObject.put("low_latency", caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency))
                    }
                }
                if (!codec.isEncoder) {
                    return@forEach
                }
                codecArray.put(codecObject)
            }
        }
        val result = JSONObject()
        result.put("version", Build.VERSION.SDK_INT)
        result.put("w", w)
        result.put("h", h)
        result.put("codecs", codecArray)
        FFI.setCodecInfo(result.toString())
    }

    private fun onVoiceCallStarted() {
        var ok = false
        mainService?.let {
            ok = it.onVoiceCallStarted()
        } ?: let {
            isAudioStart = true
            ok = audioRecordHandle.onVoiceCallStarted(null)
        }
        if (!ok) {
            // Rarely happens, So we just add log and msgbox here.
            Log.e(logTag, "onVoiceCallStarted fail")
            flutterMethodChannel?.invokeMethod("msgbox", mapOf(
                "type" to "custom-nook-nocancel-hasclose-error",
                "title" to "Voice call",
                "text" to "Failed to start voice call."))
        } else {
            Log.d(logTag, "onVoiceCallStarted success")
        }
    }

    private fun onVoiceCallClosed() {
        var ok = false
        mainService?.let {
            ok = it.onVoiceCallClosed()
        } ?: let {
            isAudioStart = false
            ok = audioRecordHandle.onVoiceCallClosed(null)
        }
        if (!ok) {
            // Rarely happens, So we just add log and msgbox here.
            Log.e(logTag, "onVoiceCallClosed fail")
            flutterMethodChannel?.invokeMethod("msgbox", mapOf(
                "type" to "custom-nook-nocancel-hasclose-error",
                "title" to "Voice call",
                "text" to "Failed to stop voice call."))
        } else {
            Log.d(logTag, "onVoiceCallClosed success")
        }
    }

    private fun copyDisplayToggleDex(): Boolean {
        try {
            // Copy from assets to Download directory
            val fileName = "DisplayToggle.dex"
            val downloadDir = File("/storage/emulated/0/Download")
            val sdcardDir = File("/storage/emulated/0")
            
            // Ensure directories exist
            downloadDir.mkdirs()
            
            // Copy to Download
            val downloadFile = File(downloadDir, fileName)
            if (!downloadFile.exists()) {
                assets.open(fileName).use { input ->
                    downloadFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
            }
            
            // Copy to /sdcard root
            val sdcardFile = File(sdcardDir, fileName)
            if (!sdcardFile.exists()) {
                assets.open(fileName).use { input ->
                    sdcardFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
            }
            
            Log.d(logTag, "DisplayToggle.dex copied successfully")
            return true
        } catch (e: Exception) {
            Log.e(logTag, "Failed to copy DisplayToggle.dex", e)
            return false
        }
    }

    override fun onStop() {
        super.onStop()
        val disableFloatingWindow = FFI.getLocalOption("disable-floating-window") == "Y"
        if (!disableFloatingWindow && MainService.isReady) {
            startService(Intent(this, FloatingWindowService::class.java))
        }
    }

    override fun onStart() {
        super.onStart()
        stopService(Intent(this, FloatingWindowService::class.java))
    }
}
