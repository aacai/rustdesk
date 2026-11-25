package zhiqiu.rd.app

import android.content.Context
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

object BrightnessController {
    private const val TAG = "BrightnessController"
    private var originalBrightness: Int = -1
    private var originalAutoBrightness: Int = -1
    private var wakeLock: PowerManager.WakeLock? = null
    private var isActive = false

    /**
     * Enable zero brightness mode - set brightness to 0 and keep screen awake.
     */
    fun enable(context: Context): Boolean {
        if (isActive) {
            Log.w(TAG, "Zero brightness mode already active")
            return true
        }

        try {
            val contentResolver = context.contentResolver

            // Save original brightness
            originalBrightness = Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS)
            Log.d(TAG, "Original brightness: $originalBrightness")

            // Save original auto-brightness mode
            try {
                originalAutoBrightness = Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS_MODE)
                // Disable auto-brightness
                Settings.System.putInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS_MODE, Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to get/set auto-brightness mode", e)
            }

            // Set brightness to 0
            Settings.System.putInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, 0)

            // Acquire WakeLock to keep screen awake
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.SCREEN_DIM_WAKE_LOCK or PowerManager.ON_AFTER_RELEASE,
                "rustdesk:zero-brightness"
            )
            wakeLock?.acquire(10 * 60 * 1000L) // 10 minutes max, will be released on disable

            isActive = true
            Log.d(TAG, "Zero brightness mode enabled")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to enable zero brightness mode", e)
            disable(context)
            return false
        }
    }

    /**
     * Disable zero brightness mode - restore original brightness.
     */
    fun disable(context: Context) {
        if (!isActive) {
            return
        }

        try {
            val contentResolver = context.contentResolver

            // Restore original brightness
            if (originalBrightness >= 0) {
                Settings.System.putInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, originalBrightness)
            }

            // Restore auto-brightness mode
            if (originalAutoBrightness >= 0) {
                Settings.System.putInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS_MODE, originalAutoBrightness)
            }

            // Release WakeLock
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                }
            }
            wakeLock = null

            isActive = false
            Log.d(TAG, "Zero brightness mode disabled, brightness restored to $originalBrightness")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to disable zero brightness mode", e)
        }
    }

    fun isActive(): Boolean = isActive
}