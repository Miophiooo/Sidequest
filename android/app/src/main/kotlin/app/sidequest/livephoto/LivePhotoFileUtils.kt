package app.sidequest.livephoto

import android.content.Context
import java.io.File

class LivePhotoFileUtils(
    private val context: Context,
) {
    fun sessionDirectory(sessionId: String): File {
        val root = File(context.cacheDir, "live_photo")
        val sessionDir = File(root, sessionId)
        if (!sessionDir.exists()) {
            sessionDir.mkdirs()
        }
        return sessionDir
    }

    fun createRollingRecordingFile(sessionId: String): File {
        return File(
            sessionDirectory(sessionId),
            "rolling_${System.currentTimeMillis()}.mp4",
        )
    }

    fun createStillPhotoFile(sessionId: String): File {
        return File(
            sessionDirectory(sessionId),
            "still_${System.currentTimeMillis()}.jpg",
        )
    }

    fun createClipFile(sessionId: String): File {
        return File(
            sessionDirectory(sessionId),
            "clip_${System.currentTimeMillis()}.mp4",
        )
    }

    fun deleteFile(file: File?) {
        if (file == null) return
        runCatching {
            if (file.exists()) {
                file.delete()
            }
        }
    }

    fun deleteSessionDirectory(sessionId: String) {
        val dir = File(File(context.cacheDir, "live_photo"), sessionId)
        if (!dir.exists()) return
        dir.deleteRecursively()
    }
}
