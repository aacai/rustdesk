package com.carriez.flutter_hbbx

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity

const val ACTION_WATCHDOG_CHECK = "com.carriez.flutter_hbbx.WATCHDOG_CHECK"
const val KEY_WATCHDOG_ENABLED = "KEY_WATCHDOG_ENABLED"
private const val WATCHDOG_INTERVAL_MS = 15 * 60 * 1000L
private const val WATCHDOG_REQUEST_CODE = 9001
private const val BOOT_FAIL_CHANNEL_ID = "RustDeskBoot"
private const val BOOT_FAIL_NOTIFY_ID = 9002

object ServiceWatchdog {
    private val logTag = "ServiceWatchdog"

    fun enable(context: Context) {
        context.getSharedPreferences(KEY_SHARED_PREFERENCES, FlutterActivity.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_WATCHDOG_ENABLED, true)
            .apply()
        schedule(context)
    }

    fun disable(context: Context) {
        context.getSharedPreferences(KEY_SHARED_PREFERENCES, FlutterActivity.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_WATCHDOG_ENABLED, false)
            .apply()
        cancel(context)
    }

    fun isEnabled(context: Context): Boolean {
        val prefs = context.getSharedPreferences(KEY_SHARED_PREFERENCES, FlutterActivity.MODE_PRIVATE)
        return prefs.getBoolean(KEY_WATCHDOG_ENABLED, false) ||
            prefs.getBoolean(KEY_START_ON_BOOT_OPT, false)
    }

    fun schedule(context: Context, delayMs: Long = WATCHDOG_INTERVAL_MS) {
        if (!isEnabled(context)) {
            return
        }
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, ServiceWatchdogReceiver::class.java).apply {
            action = ACTION_WATCHDOG_CHECK
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pendingIntent = PendingIntent.getBroadcast(context, WATCHDOG_REQUEST_CODE, intent, flags)
        val triggerAt = SystemClock.elapsedRealtime() + delayMs
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerAt,
                    pendingIntent
                )
            } else {
                alarmManager.setExact(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerAt,
                    pendingIntent
                )
            }
            Log.d(logTag, "scheduled in ${delayMs}ms")
        } catch (e: Exception) {
            Log.w(logTag, "setExact failed, fallback to set", e)
            alarmManager.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pendingIntent)
        }
    }

    fun cancel(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, ServiceWatchdogReceiver::class.java).apply {
            action = ACTION_WATCHDOG_CHECK
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pendingIntent = PendingIntent.getBroadcast(context, WATCHDOG_REQUEST_CODE, intent, flags)
        alarmManager.cancel(pendingIntent)
    }

    fun isMainServiceRunning(context: Context): Boolean {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        for (service in manager.getRunningServices(Int.MAX_VALUE)) {
            if (MainService::class.java.name == service.service.className) {
                return true
            }
        }
        return false
    }

    fun reviveMainService(context: Context, fromBoot: Boolean = false): Boolean {
        if (!isEnabled(context)) {
            Log.d(logTag, "watchdog disabled, skip revive")
            return false
        }
        if (isMainServiceRunning(context)) {
            Log.d(logTag, "MainService already running")
            RemoteMqttManager.ensureConnected(context.applicationContext)
            return true
        }
        Log.i(logTag, "reviving MainService")
        val serviceIntent = Intent(context, MainService::class.java).apply {
            action = ACT_INIT_MEDIA_PROJECTION_AND_SERVICE
            putExtra(EXT_INIT_FROM_BOOT, fromBoot)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            schedule(context)
            return true
        } catch (e: Exception) {
            Log.e(logTag, "revive MainService failed", e)
            if (fromBoot) {
                notifyBootFailure(context, e.message ?: e.javaClass.simpleName)
            }
            return false
        }
    }

    fun notifyBootFailure(context: Context, reason: String) {
        val app = context.applicationContext
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                BOOT_FAIL_CHANNEL_ID,
                "开机自启",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "开机自启失败提醒"
            }
            nm.createNotificationChannel(channel)
        }
        val launch = Intent(app, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pi = PendingIntent.getActivity(app, BOOT_FAIL_NOTIFY_ID, launch, flags)
        val notification = NotificationCompat.Builder(app, BOOT_FAIL_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_stat_logo)
            .setContentTitle("速远控 开机自启失败")
            .setContentText("远程服务未启动，请点开 App 手动开启。($reason)")
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText("远程服务未启动，请点开 App 手动开启。\n原因: $reason")
            )
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setColor(ContextCompat.getColor(app, R.color.primary))
            .build()
        nm.notify(BOOT_FAIL_NOTIFY_ID, notification)
        Log.w(logTag, "boot failure notified: $reason")
    }
}
