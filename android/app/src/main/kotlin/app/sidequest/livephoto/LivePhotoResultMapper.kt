package app.sidequest.livephoto

import java.io.File

data class LivePhotoClipResult(
    val clipFile: File,
    val actualStartEpochMs: Long,
    val actualDurationMs: Long,
    val videoWidth: Int,
    val videoHeight: Int,
    val videoFps: Int,
    // Peak loudness in dBFS over the entire clip, or null if no audio track
    // was present. -inf-style silence is reported as a very negative number
    // (e.g. -120). Used by the Dart upload service to decide whether the
    // post should be marked as having meaningful audio.
    val audioPeakDbfs: Double?,
)

object LivePhotoResultMapper {
    fun toMap(
        sessionId: String,
        photoFile: File,
        clipResult: LivePhotoClipResult,
        photoTakenAtEpochMs: Long,
        didFallbackToLatencyMode: Boolean,
    ): Map<String, Any?> {
        return mapOf(
            "sessionId" to sessionId,
            "photoPath" to photoFile.absolutePath,
            "clipPath" to clipResult.clipFile.absolutePath,
            "photoTakenAtEpochMs" to photoTakenAtEpochMs,
            "clipStartEpochMs" to clipResult.actualStartEpochMs,
            "clipDurationMs" to clipResult.actualDurationMs.toInt(),
            "videoWidth" to clipResult.videoWidth,
            "videoHeight" to clipResult.videoHeight,
            "videoFps" to clipResult.videoFps,
            "didFallbackToLatencyMode" to didFallbackToLatencyMode,
            "audioPeakDbfs" to clipResult.audioPeakDbfs,
        )
    }

    fun toStillFallbackMap(
        sessionId: String,
        photoFile: File,
        photoTakenAtEpochMs: Long,
        didFallbackToLatencyMode: Boolean,
        fallbackReason: String,
    ): Map<String, Any?> {
        return mapOf(
            "sessionId" to sessionId,
            "photoPath" to photoFile.absolutePath,
            "clipPath" to "",
            "photoTakenAtEpochMs" to photoTakenAtEpochMs,
            "clipStartEpochMs" to 0,
            "clipDurationMs" to 0,
            "videoWidth" to 0,
            "videoHeight" to 0,
            "videoFps" to 0,
            "didFallbackToLatencyMode" to didFallbackToLatencyMode,
            "isStillOnlyFallback" to true,
            "fallbackReason" to fallbackReason,
        )
    }
}
