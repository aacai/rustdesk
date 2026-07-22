package zhiqiu.rd.app

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.io.File
import java.lang.reflect.Method
import dalvik.system.DexClassLoader

object ShizukuHelper {
    private const val TAG = "ShizukuHelper"
    const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"

    /**
     * Check if Shizuku is installed.
     */
    fun isShizukuInstalled(context: Context): Boolean {
        return try {
            context.packageManager.getPackageInfo(SHIZUKU_PACKAGE, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    /**
     * Check if Shizuku service is running.
     * This requires binding to Shizuku service.
     */
    fun isShizukuRunning(context: Context): Boolean {
        // Check if Shizuku binder is available
        return try {
            val shizukuBinder: IBinder? = null // Will be set by Shizuku binding
            // For now, just check if installed
            isShizukuInstalled(context)
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Load DisplayToggle.dex and call setDisplayPowerMode.
     * This requires ADB-level permissions (via Shizuku or root).
     */
    fun setDisplayPowerMode(context: Context, mode: Int): Boolean {
        return try {
            // Path to the dex file
            val dexPath = File(context.cacheDir, "DisplayToggle.dex").absolutePath

            // Copy from assets if not exists
            if (!File(dexPath).exists()) {
                context.assets.open("DisplayToggle.dex").use { input ->
                    File(dexPath).outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
            }

            // Load the dex file
            val loader = DexClassLoader(
                dexPath,
                context.cacheDir.absolutePath,
                null,
                context.classLoader
            )

            // Load the DisplayToggle class
            val displayToggleClass = loader.loadClass("DisplayToggle")

            // Get the setDisplayPowerMode method (via reflection on SurfaceControl)
            // The DisplayToggle.main() method handles this
            val mainMethod: Method = displayToggleClass.getMethod("main", Array<String>::class.java)

            // Execute: mode 0 = OFF, mode 2 = ON
            mainMethod.invoke(null, arrayOf(mode.toString()))

            Log.d(TAG, "setDisplayPowerMode($mode) succeeded")
            true
        } catch (e: Exception) {
            Log.e(TAG, "setDisplayPowerMode failed", e)
            false
        }
    }

    /**
     * Turn screen OFF (requires ADB permission).
     */
    fun screenOff(context: Context): Boolean {
        return setDisplayPowerMode(context, 0)
    }

    /**
     * Turn screen ON.
     */
    fun screenOn(context: Context): Boolean {
        return setDisplayPowerMode(context, 2)
    }
}