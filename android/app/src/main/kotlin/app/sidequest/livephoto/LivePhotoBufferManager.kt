package app.sidequest.livephoto

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.SystemClock
import androidx.camera.video.Recording
import androidx.camera.video.VideoRecordEvent
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executor
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max

class LivePhotoBufferManager(
    private val sessionId: String,
    private val fileUtils: LivePhotoFileUtils,
) {
    private data class PendingClipRequest(
        val shutterElapsedNanos: Long,
        val shutterWallClockMs: Long,
        val preCaptureDurationMs: Int,
        val sourceFile: File,
        val callback: (LivePhotoClipResult?, Throwable?) -> Unit,
        val executor: Executor,
    )

    private var recordingStartElapsedNanos: Long = 0L
    private var pendingClipRequest: PendingClipRequest? = null

    fun onRecordingStarted(startElapsedNanos: Long) {
        recordingStartElapsedNanos = startElapsedNanos
    }

    fun stopAndExtractClip(
        recording: Recording?,
        sourceFile: File?,
        shutterElapsedNanos: Long,
        shutterWallClockMs: Long,
        preCaptureDurationMs: Int,
        executor: Executor,
        callback: (LivePhotoClipResult?, Throwable?) -> Unit,
    ) {
        if (recording == null || sourceFile == null) {
            callback(null, IllegalStateException("No active rolling recording available."))
            return
        }

        pendingClipRequest =
            PendingClipRequest(
                shutterElapsedNanos = shutterElapsedNanos,
                shutterWallClockMs = shutterWallClockMs,
                preCaptureDurationMs = preCaptureDurationMs,
                sourceFile = sourceFile,
                callback = callback,
                executor = executor,
            )
        recording.stop()
    }

    fun onVideoRecordEvent(event: VideoRecordEvent, sourceFile: File) {
        when (event) {
            is VideoRecordEvent.Start -> onRecordingStarted(SystemClock.elapsedRealtimeNanos())
            is VideoRecordEvent.Finalize -> handleFinalize(event, sourceFile)
            else -> Unit
        }
    }

    private fun handleFinalize(event: VideoRecordEvent.Finalize, sourceFile: File) {
        val request = pendingClipRequest ?: return
        pendingClipRequest = null

        request.executor.execute {
            if (event.error != VideoRecordEvent.Finalize.ERROR_NONE) {
                request.callback(
                    null,
                    IllegalStateException("CameraX recording finalize failed with error ${event.error}."),
                )
                return@execute
            }

            try {
                val clipFile = fileUtils.createClipFile(sessionId)
                val clipResult = trimToLiveWindow(
                    sourceFile = sourceFile,
                    outputFile = clipFile,
                    shutterElapsedNanos = request.shutterElapsedNanos,
                    shutterWallClockMs = request.shutterWallClockMs,
                    preCaptureDurationMs = request.preCaptureDurationMs,
                )
                request.callback(clipResult, null)
            } catch (throwable: Throwable) {
                request.callback(null, throwable)
            }
        }
    }

    private fun trimToLiveWindow(
        sourceFile: File,
        outputFile: File,
        shutterElapsedNanos: Long,
        shutterWallClockMs: Long,
        preCaptureDurationMs: Int,
    ): LivePhotoClipResult {
        val sourceElapsedMs = max(
            0L,
            (shutterElapsedNanos - recordingStartElapsedNanos) / 1_000_000L,
        )
        val desiredStartMs = max(0L, sourceElapsedMs - preCaptureDurationMs)
        val desiredEndMs = max(desiredStartMs, sourceElapsedMs)

        val extractor = MediaExtractor()
        extractor.setDataSource(sourceFile.absolutePath)

        var videoTrackIndex = -1
        var videoFormat: MediaFormat? = null
        var audioTrackIndex = -1
        var audioFormat: MediaFormat? = null
        for (index in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(index)
            val mimeType = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (videoTrackIndex == -1 && mimeType.startsWith("video/")) {
                videoTrackIndex = index
                videoFormat = format
            } else if (audioTrackIndex == -1 && mimeType.startsWith("audio/")) {
                audioTrackIndex = index
                audioFormat = format
            }
        }

        if (videoTrackIndex == -1 || videoFormat == null) {
            extractor.release()
            throw IllegalStateException("No video track found in rolling recording.")
        }

        val muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val rotationDegrees =
            if (videoFormat.containsKey(MediaFormat.KEY_ROTATION)) {
                videoFormat.getInteger(MediaFormat.KEY_ROTATION)
            } else {
                0
            }
        if (rotationDegrees in listOf(90, 180, 270)) {
            muxer.setOrientationHint(rotationDegrees)
        }
        val videoOutIndex = muxer.addTrack(videoFormat)
        val audioOutIndex = if (audioFormat != null) muxer.addTrack(audioFormat) else -1
        muxer.start()

        val maxInputSize =
            if (videoFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                videoFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
            } else {
                1 * 1024 * 1024
            }
        val buffer = ByteBuffer.allocate(maxInputSize)
        val bufferInfo = MediaCodec.BufferInfo()

        var firstWrittenSampleUs = -1L
        var lastWrittenSampleUs = -1L

        // Pass 1 — video track only, in stream order so the muxer is happy.
        extractor.selectTrack(videoTrackIndex)
        extractor.seekTo(desiredStartMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        while (true) {
            val sampleTimeUs = extractor.sampleTime
            if (sampleTimeUs < 0) break
            if (sampleTimeUs > desiredEndMs * 1000L) break

            bufferInfo.offset = 0
            bufferInfo.size = extractor.readSampleData(buffer, 0)
            if (bufferInfo.size <= 0) break

            if (firstWrittenSampleUs == -1L) {
                firstWrittenSampleUs = sampleTimeUs
            }

            bufferInfo.presentationTimeUs = sampleTimeUs - firstWrittenSampleUs
            bufferInfo.flags = extractor.sampleFlags
            muxer.writeSampleData(videoOutIndex, buffer, bufferInfo)
            lastWrittenSampleUs = sampleTimeUs
            extractor.advance()
        }
        extractor.unselectTrack(videoTrackIndex)

        // Pass 2 — audio track in the same window. Skipped entirely when the
        // rolling recording had no audio (mic permission denied or muteVideo).
        if (audioTrackIndex != -1 && audioOutIndex != -1 && firstWrittenSampleUs != -1L) {
            extractor.selectTrack(audioTrackIndex)
            extractor.seekTo(desiredStartMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            while (true) {
                val sampleTimeUs = extractor.sampleTime
                if (sampleTimeUs < 0) break
                if (sampleTimeUs > desiredEndMs * 1000L) break
                bufferInfo.offset = 0
                bufferInfo.size = extractor.readSampleData(buffer, 0)
                if (bufferInfo.size <= 0) break
                bufferInfo.presentationTimeUs = max(0L, sampleTimeUs - firstWrittenSampleUs)
                bufferInfo.flags = extractor.sampleFlags
                muxer.writeSampleData(audioOutIndex, buffer, bufferInfo)
                extractor.advance()
            }
        }

        try {
            muxer.stop()
        } finally {
            muxer.release()
            extractor.release()
        }

        if (firstWrittenSampleUs == -1L || lastWrittenSampleUs == -1L) {
            throw IllegalStateException("No samples were written for the live photo clip window.")
        }

        // After the clip is finalized, decode its audio (if any) and compute
        // peak loudness in dBFS. Used by the Dart side to decide whether to
        // upload the audio track or strip it.
        val audioPeakDbfs = if (audioTrackIndex != -1) {
            try {
                measureAudioPeakDbfs(outputFile)
            } catch (_: Throwable) {
                null
            }
        } else {
            null
        }

        val actualDurationMs = max(
            1L,
            (lastWrittenSampleUs - firstWrittenSampleUs) / 1000L,
        )
        val actualStartEpochMs = shutterWallClockMs - actualDurationMs
        val videoWidth =
            if (videoFormat.containsKey(MediaFormat.KEY_WIDTH)) {
                videoFormat.getInteger(MediaFormat.KEY_WIDTH)
            } else {
                0
            }
        val videoHeight =
            if (videoFormat.containsKey(MediaFormat.KEY_HEIGHT)) {
                videoFormat.getInteger(MediaFormat.KEY_HEIGHT)
            } else {
                0
            }
        val videoFps =
            if (videoFormat.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                videoFormat.getInteger(MediaFormat.KEY_FRAME_RATE)
            } else {
                0
            }

        return LivePhotoClipResult(
            clipFile = outputFile,
            actualStartEpochMs = actualStartEpochMs,
            actualDurationMs = actualDurationMs,
            videoWidth = videoWidth,
            videoHeight = videoHeight,
            videoFps = videoFps,
            audioPeakDbfs = audioPeakDbfs,
        )
    }

    /// Decode the audio track of [clipFile] and return the peak amplitude in
    /// dBFS. Returns -120.0 (effectively silence floor) when the track is
    /// present but empty, and surfaces null via the caller if anything below
    /// throws.
    private fun measureAudioPeakDbfs(clipFile: File): Double {
        val extractor = MediaExtractor()
        extractor.setDataSource(clipFile.absolutePath)
        var audioTrackIndex = -1
        var audioFormat: MediaFormat? = null
        for (index in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(index)
            val mimeType = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mimeType.startsWith("audio/")) {
                audioTrackIndex = index
                audioFormat = format
                break
            }
        }
        if (audioTrackIndex == -1 || audioFormat == null) {
            extractor.release()
            return -120.0
        }
        extractor.selectTrack(audioTrackIndex)

        val mime = audioFormat.getString(MediaFormat.KEY_MIME)!!
        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(audioFormat, null, null, 0)
        codec.start()

        val info = MediaCodec.BufferInfo()
        var sawInputEos = false
        var sawOutputEos = false
        var peakSample = 0

        while (!sawOutputEos) {
            if (!sawInputEos) {
                val inIndex = codec.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    val inBuf = codec.getInputBuffer(inIndex)!!
                    val sampleSize = extractor.readSampleData(inBuf, 0)
                    if (sampleSize < 0) {
                        codec.queueInputBuffer(
                            inIndex, 0, 0, 0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                        )
                        sawInputEos = true
                    } else {
                        codec.queueInputBuffer(
                            inIndex, 0, sampleSize, extractor.sampleTime, 0,
                        )
                        extractor.advance()
                    }
                }
            }

            val outIndex = codec.dequeueOutputBuffer(info, 10_000)
            if (outIndex >= 0) {
                if (info.size > 0) {
                    val outBuf = codec.getOutputBuffer(outIndex)!!
                    outBuf.position(info.offset)
                    outBuf.limit(info.offset + info.size)
                    val shortBuf = outBuf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                    while (shortBuf.hasRemaining()) {
                        val s = abs(shortBuf.get().toInt())
                        if (s > peakSample) peakSample = s
                    }
                }
                codec.releaseOutputBuffer(outIndex, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                    sawOutputEos = true
                }
            }
        }

        codec.stop()
        codec.release()
        extractor.release()

        if (peakSample <= 0) return -120.0
        val normalized = peakSample.toDouble() / Short.MAX_VALUE.toDouble()
        return 20.0 * log10(normalized)
    }
}
