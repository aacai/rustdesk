package com.carriez.flutter_hbbx

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/** Lightweight FGS: keeps MQTT connected so remote commands work even when MainService is killed. */
class MqttCommandService : Service() {
    private val logTag = "MqttCommandService"

    override fun onCreate() {
        super.onCreate()
        Log.i(logTag, "onCreate")
        startForeground(NOTIFY_ID, buildNotification())
        ServiceWatchdog.enable(applicationContext)
        RemoteMqttManager.start(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        RemoteMqttManager.ensureConnected(applicationContext)
        ServiceWatchdog.schedule(applicationContext)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        ServiceWatchdog.schedule(applicationContext, delayMs = 30_000L)
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        ServiceWatchdog.schedule(applicationContext, delayMs = 15_000L)
        val restart = Intent(applicationContext, MqttCommandService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(restart)
        } else {
            startService(restart)
        }
        super.onTaskRemoved(rootIntent)
    }

    private fun buildNotification(): android.app.Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "远程协助", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "保持 MQTT 连接，接收远程指令"
                }
            )
        }
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_stat_logo)
            .setContentTitle("远程协助待命")
            .setContentText("MQTT 已连接，可接收远程指令")
            .setOngoing(true)
            .setContentIntent(pi)
            .setColor(ContextCompat.getColor(this, R.color.primary))
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "RustDeskMqtt"
        private const val NOTIFY_ID = 9003

        fun start(context: Context) {
            val intent = Intent(context, MqttCommandService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e("MqttCommandService", "start failed", e)
            }
        }
    }
}
