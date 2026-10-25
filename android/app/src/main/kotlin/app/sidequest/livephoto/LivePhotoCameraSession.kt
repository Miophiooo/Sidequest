package app.sidequest.livephoto

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.camera.core.AspectRatio
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class LivePhotoCameraSession(
    private val sessionId: String,
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val config: LivePhotoConfig,
    private val eventEmitter: (Map<String, Any?>) -> Unit,
) {
    private val mainExecutor = ContextCompat.getMainExecutor(context)
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val fileUtils = LivePhotoFileUtils(context)
    private val bufferManager = LivePhotoBufferManager(sessionId, fileUtils)
    private val captureInProgress = AtomicBoolean(false)

    private var previewView: PreviewView? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var previewUseCase: Preview? = null
    private var imageCapture: ImageCapture? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var activeRecording: Recording? = null
    private var rollingFile: File? = null
    private var isStarted = false
    private var shouldPreserveOutputFiles = false
    private var pendingFlashMode: Int = ImageCapture.FLASH_MODE_OFF

    private val sessionTimeoutRunnable =
        Runnable {
            if (!isStarted || captureInProgress.get()) {
                return@Runnable
            }
            activeRecording?.stop()
            activeRecording = null
            cameraProvider?.unbindAll()
            fileUtils.deleteFile(rollingFile)
            rollingFile = null
            isStarted = false
            emitError(
                "sessionTimedOut",
                "Live photo session expired. Reopen live capture to try again.",
            )
        }

    fun capabilities(): Map<String, Any?> {
        return mapOf(
            "isSupported" to true,
            "supportsFrontCamera" to true,
            // CameraX disables practical ZSL value once VideoCapture is bound.
            "supportsZeroShutterLag" to false,
            "supportedQualities" to listOf("HD", "SD"),
        )
    }

    fun attachPreview(view: PreviewView) {
        previewView = view
        previewUseCase?.setSurfaceProvider(view.surfaceProvider)
    }

    fun detachPreview(view: PreviewView) {
        if (previewView === view) {
            previewView = null
        }
    }

    fun start(callback: (Throwable?) -> Unit) {
        if (isStarted) {
            callback(null)
            return
        }

        emitState("initializing", "Starting live photo camera.")
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener(
            {
                try {
                    val provider = providerFuture.get()
                    cameraProvider = provider
                    bindUseCases(provider)
                    startRollingRecording()
                    scheduleSessionTimeout()
                    isStarted = true
                    emitState("buffering", "Rolling pre-capture recording started.")
                    callback(null)
                } catch (throwable: Throwable) {
                    emitError("unknown", throwable.message ?: "Failed to start camera session.")
                    callback(throwable)
                }
            },
            mainExecutor,
        )
    }

    fun stop() {
        cancelSessionTimeout()
        activeRecording?.stop()
        activeRecording = null
        cameraProvider?.unbindAll()
        if (!shouldPreserveOutputFiles) {
            fileUtils.deleteFile(rollingFile)
            rollingFile = null
        }
        isStarted = false
        emitState("stopped", "Live photo session stopped.")
    }

    fun dispose() {
        stop()
        if (!shouldPreserveOutputFiles) {
            fileUtils.deleteSessionDirectory(sessionId)
        }
        ioExecutor.shutdown()
    }

    fun setFlashMode(mode: String) {
        val resolved =
            when (mode.lowercase()) {
                "on" -> ImageCapture.FLASH_MODE_ON
                "auto" -> ImageCapture.FLASH_MODE_AUTO
                else -> ImageCapture.FLASH_MODE_OFF
            }
        pendingFlashMode = resolved
        imageCapture?.flashMode = resolved
    }

    fun capture(callback: (Map<String, Any?>?, Throwable?) -> Unit) {
        if (!isStarted) {
            callback(null, IllegalStateException("Live photo session has not started yet."))
            return
        }

        if (!captureInProgress.compareAndSet(false, true)) {
            callback(null, IllegalStateException("A live photo capture is already in progress."))
            return
        }

        val imageCapture = imageCapture
        if (imageCapture == null) {
            captureInProgress.set(false)
            callback(null, IllegalStateException("ImageCapture is unavailable."))
            return
        }

        val photoFile = fileUtils.createStillPhotoFile(sessionId)
        val outputOptions = ImageCapture.OutputFileOptions.Builder(photoFile).build()
        val shutterElapsedNanos = SystemClock.elapsedRealtimeNanos()
        val shutterWallClockMs = System.currentTimeMillis()
        cancelSessionTimeout()

        emitState("capturing", "Capturing still photo and extracting live clip.")
        imageCapture.takePicture(
            outputOptions,
            ioExecutor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    val recording = activeRecording
                    activeRecording = null
                    val sourceFile = rollingFile
                    bufferManager.stopAndExtractClip(
                        recording = recording,
                        sourceFile = sourceFile,
                        shutterElapsedNanos = shutterElapsedNanos,
                        shutterWallClockMs = shutterWallClockMs,
                        preCaptureDurationMs = config.preCaptureDurationMs,
                        executor = ioExecutor,
                    ) { clipResult, error ->
                        captureInProgress.set(false)
                        fileUtils.deleteFile(sourceFile)
                        rollingFile = null
                        if (error != null || clipResult == null) {
                            shouldPreserveOutputFiles = true
                            emitState(
                                "stopped",
                                "Live clip failed. Falling back to still photo.",
                            )
                            callback(
                                LivePhotoResultMapper.toStillFallbackMap(
                                    sessionId = sessionId,
                                    photoFile = photoFile,
                                    photoTakenAtEpochMs = shutterWallClockMs,
                                    didFallbackToLatencyMode = true,
                                    fallbackReason = "clipGenerationFailed",
                                ),
                                null,
                            )
                        } else {
                            shouldPreserveOutputFiles = true
                            emitState("stopped", "Live photo ready.")
                            callback(
                                LivePhotoResultMapper.toMap(
                                    sessionId = sessionId,
                                    photoFile = photoFile,
                                    clipResult = clipResult,
                                    photoTakenAtEpochMs = shutterWallClockMs,
                                    didFallbackToLatencyMode = true,
                                ),
                                null,
                            )
                        }
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    captureInProgress.set(false)
                    scheduleSessionTimeout()
                    emitError(
                        "photoCaptureFailed",
                        exception.message ?: "Still photo capture failed.",
                    )
                    callback(null, exception)
                }
            },
        )
    }

    private fun bindUseCases(provider: ProcessCameraProvider) {
        val lensFacing =
            if (config.lensFacing.equals("front", ignoreCase = true)) {
                CameraSelector.LENS_FACING_FRONT
            } else {
                CameraSelector.LENS_FACING_BACK
            }

        val preview =
            Preview.Builder()
                .setTargetAspectRatio(AspectRatio.RATIO_16_9)
                .build()
        val imageCapture =
            ImageCapture.Builder()
                .setTargetAspectRatio(AspectRatio.RATIO_16_9)
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                .setFlashMode(pendingFlashMode)
                .build()
        // 720p at ~2 Mbit/s: a ~2 s clip stays around 0.5 MB in storage.
        val recorder =
            Recorder.Builder()
                .setQualitySelector(
                    QualitySelector.fromOrderedList(
                        listOf(Quality.HD, Quality.SD),
                        FallbackStrategy.lowerQualityOrHigherThan(Quality.SD),
                    ),
                )
                .setTargetVideoEncodingBitRate(CLIP_BIT_RATE)
                .build()
        val videoCapture = VideoCapture.withOutput(recorder)
        val selector =
            CameraSelector.Builder()
                .requireLensFacing(lensFacing)
                .build()

        provider.unbindAll()
        val useCases: Array<UseCase> = arrayOf(preview, imageCapture, videoCapture)
        provider.bindToLifecycle(lifecycleOwner, selector, *useCases)

        previewView?.let { preview.setSurfaceProvider(it.surfaceProvider) }

        this.previewUseCase = preview
        this.imageCapture = imageCapture
        this.videoCapture = videoCapture
    }

    @SuppressLint("MissingPermission")
    private fun startRollingRecording() {
        val capture = videoCapture ?: throw IllegalStateException("VideoCapture unavailable.")
        val file = fileUtils.createRollingRecordingFile(sessionId)
        rollingFile = file
        val outputOptions = FileOutputOptions.Builder(file).build()

        // Audio is best-effort: we only enable it when the user has actually
        // granted RECORD_AUDIO AND the session config didn't opt out. Without
        // the permission CameraX would throw at prepareRecording time.
        val micGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        val pendingRecording = capture.output.prepareRecording(context, outputOptions)
        val withAudio = micGranted && !config.muteVideo
        if (withAudio) {
            pendingRecording.withAudioEnabled()
        }

        activeRecording =
            pendingRecording
                .start(mainExecutor) { event ->
                    bufferManager.onVideoRecordEvent(event, file)
                    when (event) {
                        is VideoRecordEvent.Start -> {
                            emitState("buffering", "Rolling pre-capture buffer active.")
                        }

                        is VideoRecordEvent.Finalize -> {
                            if (!captureInProgress.get()) {
                                emitState("stopped", "Rolling recording finalized.")
                            }
                        }

                        else -> Unit
                    }
                }
    }

    private fun scheduleSessionTimeout() {
        cancelSessionTimeout()
        mainHandler.postDelayed(sessionTimeoutRunnable, config.sessionTimeoutMs.toLong())
    }

    private fun cancelSessionTimeout() {
        mainHandler.removeCallbacks(sessionTimeoutRunnable)
    }

    private fun emitState(state: String, message: String) {
        eventEmitter(
            mapOf(
                "sessionId" to sessionId,
                "state" to state,
                "message" to message,
            ),
        )
    }

    private fun emitError(code: String, message: String) {
        eventEmitter(
            mapOf(
                "sessionId" to sessionId,
                "state" to "error",
                "message" to message,
                "errorCode" to code,
            ),
        )
    }
}

private const val CLIP_BIT_RATE = 2_000_000
