package zhiqiu.rd.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import androidx.core.content.ContextCompat
import com.hjq.permissions.Permission
import com.hjq.permissions.XXPermissions
import ffi.FFI
import java.nio.ByteBuffer

// Captures the device camera and feeds RGBA frames into the Rust video pipeline
// through the dedicated camera raw buffer (FFI.onCameraFrameUpdate).
class CameraService(private val context: Context) {
    private val logTag = "CameraService"

    private var cameraManager: CameraManager? = null
    private var cameraId: String? = null

    private var imageReader: ImageReader? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: android.hardware.camera2.CameraCaptureSession? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    private var rgbaBuffer: ByteBuffer? = null
    private var width = 0
    private var height = 0

    @Volatile
    private var running = false

    // Returns the capture size that will be used, without opening the camera.
    fun getCameraSize(): Size {
        ensureManager()
        val id = cameraId ?: return Size(1280, 720)
        return try {
            val characteristics = cameraManager!!.getCameraCharacteristics(id)
            val map =
                characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val sizes =
                map?.getOutputSizes(ImageFormat.YUV_420_888) ?: return Size(1280, 720)
            sizes
                .filter { it.width <= 1920 && it.height <= 1080 }
                .minByOrNull { kotlin.math.abs(it.width - 1280) + kotlin.math.abs(it.height - 720) }
                ?: sizes.first()
        } catch (e: Exception) {
            Log.w(logTag, "getCameraSize failed: $e")
            Size(1280, 720)
        }
    }

    @SuppressLint("MissingPermission")
    fun start() {
        if (running) return
        if (!hasCameraPermission()) {
            requestCameraPermission()
            return
        }
        ensureManager()
        val id = cameraId ?: run {
            Log.w(logTag, "no camera available")
            return
        }
        val size = getCameraSize()
        width = size.width
        height = size.height
        rgbaBuffer = ByteBuffer.allocateDirect(width * height * 4)
        thread = HandlerThread("camera-thread").also { it.start() }
        handler = Handler(thread!!.looper)
        imageReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 2).apply {
            setOnImageAvailableListener({ reader ->
                try {
                    reader.acquireLatestImage()?.use { image ->
                        if (!running) return@setOnImageAvailableListener
                        val buf = yuv420ToRgba(image, rgbaBuffer!!)
                        FFI.onCameraFrameUpdate(buf)
                    }
                } catch (ignored: Exception) {
                }
            }, handler)
        }
        FFI.setFrameRawEnable("camera", true)
        try {
            cameraManager!!.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    cameraDevice = device
                    val surface = imageReader!!.surface
                    device.createCaptureSession(listOf(surface),
                        object : android.hardware.camera2.CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: android.hardware.camera2.CameraCaptureSession) {
                                captureSession = session
                                val request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                                    .apply { addTarget(surface) }
                                    .build()
                                session.setRepeatingRequest(request, null, handler)
                                running = true
                                Log.d(logTag, "camera started ${width}x$height")
                            }

                            override fun onConfigureFailed(session: android.hardware.camera2.CameraCaptureSession) {
                                Log.w(logTag, "camera capture session configure failed")
                            }
                        }, handler)
                }

                override fun onDisconnected(device: CameraDevice) {
                    device.close()
                }

                override fun onError(device: CameraDevice, error: Int) {
                    device.close()
                }
            }, handler)
        } catch (e: Exception) {
            Log.w(logTag, "openCamera failed: $e")
        }
    }

    private fun hasCameraPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context, Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestCameraPermission() {
        XXPermissions.with(context)
            .permission(Permission.CAMERA)
            .request { _, all ->
                if (all) {
                    start()
                } else {
                    Log.w(logTag, "camera permission denied")
                }
            }
    }

    fun stop() {
        if (!running && cameraDevice == null) return
        running = false
        FFI.setFrameRawEnable("camera", false)
        try {
            captureSession?.close()
        } catch (_: Exception) {
        }
        try {
            cameraDevice?.close()
        } catch (_: Exception) {
        }
        try {
            imageReader?.close()
        } catch (_: Exception) {
        }
        captureSession = null
        cameraDevice = null
        imageReader = null
        rgbaBuffer = null
        thread?.quitSafely()
        thread = null
        handler = null
        Log.d(logTag, "camera stopped")
    }

    private fun ensureManager() {
        if (cameraManager == null) {
            cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            cameraId = cameraManager!!.cameraIdList.firstOrNull { id ->
                val facing = cameraManager!!.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING)
                facing == CameraCharacteristics.LENS_FACING_FRONT
            } ?: cameraManager!!.cameraIdList.firstOrNull()
        }
    }

    // Converts an Android YUV_420_888 image into a tightly packed RGBA_8888 buffer.
    private fun yuv420ToRgba(image: android.media.Image, out: ByteBuffer): ByteBuffer {
        val width = image.width
        val height = image.height
        val planes = image.planes
        val yPlane = planes[0].buffer
        val uPlane = planes[1].buffer
        val vPlane = planes[2].buffer
        val yRowStride = planes[0].rowStride
        val uvRowStride = planes[1].rowStride
        val uvPixelStride = planes[1].pixelStride
        out.clear()
        var yOffset = 0
        for (y in 0 until height) {
            val uvOffset = (y shr 1) * uvRowStride
            for (x in 0 until width) {
                val yValue = yPlane[yOffset + x].toInt() and 0xff
                val uvIndex = uvOffset + (x shr 1) * uvPixelStride
                val uValue = uPlane[uvIndex].toInt() and 0xff
                val vValue = vPlane[uvIndex].toInt() and 0xff
                // BT.601 full range
                val r = yValue + (1436 * (vValue - 128) shr 10)
                val g = yValue - (465 * (uValue - 128) shr 10) - (936 * (vValue - 128) shr 10)
                val b = yValue + (1814 * (uValue - 128) shr 10)
                out.put(clamp(r))
                out.put(clamp(g))
                out.put(clamp(b))
                out.put(255.toByte())
            }
            yOffset += yRowStride
        }
        out.rewind()
        return out
    }

    private fun clamp(v: Int): Byte {
        return (if (v < 0) 0 else if (v > 255) 255 else v).toByte()
    }
}
