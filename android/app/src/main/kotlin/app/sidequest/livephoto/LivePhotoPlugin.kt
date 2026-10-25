package app.sidequest.livephoto

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class LivePhotoPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var applicationContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private val sessions = ConcurrentHashMap<String, LivePhotoCameraSession>()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel =
            MethodChannel(binding.binaryMessenger, "sidequest/live_photo/methods").also {
                it.setMethodCallHandler(this)
            }
        eventChannel =
            EventChannel(binding.binaryMessenger, "sidequest/live_photo/events").also {
                it.setStreamHandler(this)
            }
        binding.platformViewRegistry.registerViewFactory(
            "sidequest/live_photo/preview",
            LivePhotoPreviewFactory { sessionId -> sessions[sessionId] },
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        sessions.values.forEach { it.dispose() }
        sessions.clear()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensurePermissions" -> ensurePermissions(result)
            "initializeLivePhotoCamera" -> initializeSession(call, result)
            "startSession" -> startSession(call, result)
            "stopSession" -> stopSession(call, result)
            "captureLivePhoto" -> captureLivePhoto(call, result)
            "setFlashMode" -> setFlashMode(call, result)
            "dispose" -> disposeSession(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CAMERA_PERMISSION) {
            return false
        }

        // Camera is the hard requirement — mic denial is acceptable and
        // simply produces audio-less clips.
        var cameraGranted = false
        permissions.forEachIndexed { idx, permission ->
            if (permission == Manifest.permission.CAMERA &&
                idx < grantResults.size &&
                grantResults[idx] == PackageManager.PERMISSION_GRANTED
            ) {
                cameraGranted = true
            }
        }
        // If camera wasn't in this request, it must have already been granted.
        if (!permissions.contains(Manifest.permission.CAMERA)) cameraGranted = true
        pendingPermissionResult?.success(cameraGranted)
        pendingPermissionResult = null
        return true
    }

    private fun ensurePermissions(result: MethodChannel.Result) {
        val activity = activity
        if (activity == null) {
            result.error("unsupported", "Live photo activity context is unavailable.", null)
            return
        }

        val cameraGranted =
            ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.CAMERA,
            ) == PackageManager.PERMISSION_GRANTED
        val micGranted =
            ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED
        // Camera is required, mic is optional — capture still succeeds without
        // audio. We report success on camera-only so users who deny mic keep
        // the live-photo flow; the rolling recorder will silently skip audio.
        if (cameraGranted && micGranted) {
            result.success(true)
            return
        }

        if (pendingPermissionResult != null) {
            result.error("permissionDenied", "A permission request is already active.", null)
            return
        }

        val needed = mutableListOf<String>()
        if (!cameraGranted) needed.add(Manifest.permission.CAMERA)
        if (!micGranted) needed.add(Manifest.permission.RECORD_AUDIO)

        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            activity,
            needed.toTypedArray(),
            REQUEST_CAMERA_PERMISSION,
        )
    }

    private fun initializeSession(call: MethodCall, result: MethodChannel.Result) {
        val activity = activity
        val lifecycleOwner = activity as? LifecycleOwner
        if (activity == null || lifecycleOwner == null) {
            result.error("unsupported", "Camera lifecycle host is unavailable.", null)
            return
        }

        val arguments = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        val configMap = arguments["config"] as? Map<*, *> ?: emptyMap<String, Any?>()
        val config = LivePhotoConfig.fromMap(configMap)
        val sessionId = UUID.randomUUID().toString()
        val session =
            LivePhotoCameraSession(
                sessionId = sessionId,
                context = applicationContext,
                lifecycleOwner = lifecycleOwner,
                config = config,
            ) { event ->
                emitEvent(event)
            }

        sessions[sessionId] = session
        result.success(
            mapOf(
                "sessionId" to sessionId,
                "capabilities" to session.capabilities(),
            ),
        )
    }

    private fun startSession(call: MethodCall, result: MethodChannel.Result) {
        val session = sessionForCall(call, result) ?: return
        session.start { error ->
            if (error != null) {
                result.error("unknown", error.message, null)
            } else {
                result.success(null)
            }
        }
    }

    private fun stopSession(call: MethodCall, result: MethodChannel.Result) {
        val session = sessionForCall(call, result) ?: return
        session.stop()
        result.success(null)
    }

    private fun captureLivePhoto(call: MethodCall, result: MethodChannel.Result) {
        val session = sessionForCall(call, result) ?: return
        session.capture { payload, error ->
            if (error != null) {
                val code =
                    when {
                        error.message?.contains("clip", ignoreCase = true) == true -> "clipGenerationFailed"
                        error.message?.contains("photo", ignoreCase = true) == true -> "photoCaptureFailed"
                        error.message?.contains("progress", ignoreCase = true) == true -> "captureInProgress"
                        else -> "unknown"
                    }
                result.error(code, error.message, null)
            } else {
                result.success(payload)
            }
        }
    }

    private fun setFlashMode(call: MethodCall, result: MethodChannel.Result) {
        val session = sessionForCall(call, result) ?: return
        val mode = call.argument<String>("mode") ?: "off"
        session.setFlashMode(mode)
        result.success(null)
    }

    private fun disposeSession(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        if (sessionId.isNullOrBlank()) {
            result.error("sessionMissing", "Missing live photo session id.", null)
            return
        }

        sessions.remove(sessionId)?.dispose()
        result.success(null)
    }

    private fun sessionForCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ): LivePhotoCameraSession? {
        val sessionId = call.argument<String>("sessionId")
        if (sessionId.isNullOrBlank()) {
            result.error("sessionMissing", "Missing live photo session id.", null)
            return null
        }
        val session = sessions[sessionId]
        if (session == null) {
            result.error("sessionMissing", "Live photo session not found.", null)
            return null
        }
        return session
    }

    private fun emitEvent(event: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(event)
        }
    }

    companion object {
        private const val REQUEST_CAMERA_PERMISSION = 4207
    }
}
