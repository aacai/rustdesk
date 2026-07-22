package zhiqiu.rd.app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.*
import android.widget.FrameLayout
import android.widget.Toast
import android.view.GestureDetector
import android.view.MotionEvent
import android.os.Handler
import android.os.Looper
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.provider.Settings

class BlackScreenService : Service() {

    companion object {
        private const val TAG = "BlackScreenService"
        var isRunning = false
        private var windowManager: WindowManager? = null
        private var overlayView: View? = null

        fun start(context: Context): Boolean {
            if (isRunning) return true

            // Check overlay permission
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (!Settings.canDrawOverlays(context)) {
                    Log.w(TAG, "Overlay permission not granted")
                    return false
                }
            }

            val intent = Intent(context, BlackScreenService::class.java)
            context.startService(intent)
            return true
        }

        fun stop(context: Context) {
            if (!isRunning) return
            val intent = Intent(context, BlackScreenService::class.java)
            context.stopService(intent)
        }
    }

    private lateinit var gestureDetector: GestureDetector
    private val handler = Handler(Looper.getMainLooper())
    private var longPressRunnable: Runnable? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate")
        isRunning = true
        showOverlay()
        setupScreenOffReceiver()

        // Show exit hint after delay
        handler.postDelayed({
            Toast.makeText(this, "双击或长按 3 秒退出", Toast.LENGTH_LONG).show()
        }, 500)
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy")
        removeOverlay()
        isRunning = false
        unregisterReceiver(screenOffReceiver)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun showOverlay() {
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        val layoutParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_FULLSCREEN or
                WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS or
                WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS or
                WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION,
            PixelFormat.OPAQUE
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // Extend the black overlay under notches / display cutouts as well.
            layoutParams.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }

        overlayView = createOverlayView()
        windowManager?.addView(overlayView, layoutParams)
        applyImmersiveMode(overlayView!!)
    }

    private fun createOverlayView(): View {
        val container = OverlayContainer(this)
        container.setBackgroundColor(android.graphics.Color.BLACK)
        container.keepScreenOn = true

        gestureDetector = GestureDetector(this, GestureListener())

        container.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    startLongPressDetection()
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    cancelLongPressDetection()
                }
            }
            gestureDetector.onTouchEvent(event)
            true
        }

        return container
    }

    // Status bar / navigation bar are separate system windows drawn above a plain
    // TYPE_APPLICATION_OVERLAY, so translucent/fullscreen flags alone cannot cover them.
    // We have to explicitly ask the system to hide them (immersive mode).
    private fun applyImmersiveMode(view: View) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            view.windowInsetsController?.let { controller ->
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            view.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                )
        }
    }

    // Re-applies immersive mode whenever the overlay window regains focus, since the system
    // may temporarily reveal the status/navigation bars (e.g. after a swipe from the edge).
    private inner class OverlayContainer(context: Context) : FrameLayout(context) {
        override fun onWindowFocusChanged(hasFocus: Boolean) {
            super.onWindowFocusChanged(hasFocus)
            if (hasFocus && isRunning) {
                applyImmersiveMode(this)
            }
        }
    }

    private fun startLongPressDetection() {
        longPressRunnable = Runnable {
            Log.d(TAG, "Long press detected, exiting black screen")
            stopSelf()
        }
        handler.postDelayed(longPressRunnable!!, 3000)
    }

    private fun cancelLongPressDetection() {
        longPressRunnable?.let { handler.removeCallbacks(it) }
    }

    private inner class GestureListener : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent): Boolean = true

        override fun onDoubleTap(e: MotionEvent): Boolean {
            Log.d(TAG, "Double tap detected, exiting black screen")
            stopSelf()
            return true
        }

        override fun onFling(
            e1: MotionEvent?,
            e2: MotionEvent,
            velocityX: Float,
            velocityY: Float
        ): Boolean {
            if (e1 != null && e2.y - e1.y < -200 && velocityY < -500) {
                Log.d(TAG, "Swipe up detected, exiting black screen")
                stopSelf()
                return true
            }
            return false
        }
    }

    private fun removeOverlay() {
        overlayView?.let {
            windowManager?.removeViewImmediate(it)
            overlayView = null
        }
    }

    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) {
                Log.d(TAG, "Screen off detected, stopping black screen service")
                stopSelf()
            }
        }
    }

    private fun setupScreenOffReceiver() {
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        registerReceiver(screenOffReceiver, filter)
    }
}