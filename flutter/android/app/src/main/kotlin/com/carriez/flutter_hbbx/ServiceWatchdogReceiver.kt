package com.carriez.flutter_hbbx

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class ServiceWatchdogReceiver : BroadcastReceiver() {
    private val logTag = "ServiceWatchdogRx"

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_WATCHDOG_CHECK) {
            return
        }
        Log.d(logTag, "watchdog tick")
        val app = context.applicationContext
        MqttCommandService.start(app)
        ServiceWatchdog.reviveMainService(app)
        ServiceWatchdog.schedule(app)
    }
}
