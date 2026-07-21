package zhiqiu.rd.app

import android.app.Application
import android.util.Log
import ffi.FFI

class MainApplication : Application() {
    companion object {
        private const val TAG = "MainApplication"
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "App start")
        try {
            FFI.onAppStart(applicationContext)
        } catch (t: Throwable) {
            // Surface native (librustdesk.so) load/link errors clearly in logcat
            // instead of a bare UnsatisfiedLinkError crash.
            Log.e(TAG, "FFI init failed (likely librustdesk.so load/link error)", t)
            throw t
        }
    }
}
