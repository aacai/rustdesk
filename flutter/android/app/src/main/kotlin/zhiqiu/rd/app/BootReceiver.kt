package zhiqiu.rd.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

const val DEBUG_BOOT_COMPLETED = "zhiqiu.rd.app.DEBUG_BOOT_COMPLETED"

private const val BOOT_VERIFY_DELAY_MS = 12_000L

class BootReceiver : BroadcastReceiver() {
    private val logTag = "tagBootReceiver"

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(logTag, "onReceive ${intent.action}")

        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            action != DEBUG_BOOT_COMPLETED
        ) {
            return
        }

        val appContext = context.applicationContext
        MqttCommandService.start(appContext)
        ServiceWatchdog.enable(appContext)

        val prefs = context.getSharedPreferences(KEY_SHARED_PREFERENCES, FlutterActivity.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_START_ON_BOOT_OPT, false)) {
            Log.d(logTag, "start on boot off — MQTT only")
            return
        }

        val pendingResult = goAsync()
        try {
            val started = ServiceWatchdog.reviveMainService(appContext, fromBoot = true)
            if (!started) {
                pendingResult.finish()
                return
            }
            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    if (!ServiceWatchdog.isMainServiceRunning(appContext)) {
                        Log.w(logTag, "MainService not running after boot delay, retry once")
                        val ok = ServiceWatchdog.reviveMainService(appContext, fromBoot = true)
                        if (ok && !ServiceWatchdog.isMainServiceRunning(appContext)) {
                            ServiceWatchdog.notifyBootFailure(
                                appContext,
                                "开机后服务未保持运行"
                            )
                        }
                    }
                } finally {
                    pendingResult.finish()
                }
            }, BOOT_VERIFY_DELAY_MS)
        } catch (e: Exception) {
            Log.e(logTag, "boot start failed", e)
            ServiceWatchdog.notifyBootFailure(appContext, e.message ?: e.javaClass.simpleName)
            pendingResult.finish()
        }
    }
}
