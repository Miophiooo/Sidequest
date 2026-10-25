package app.sidequest.livephoto

data class LivePhotoConfig(
    val lensFacing: String = "back",
    val preCaptureDurationMs: Int = 2000,
    val targetClipDurationMs: Int = 2000,
    val sessionTimeoutMs: Int = 45_000,
    val preferredQuality: String = "HD",
    val muteVideo: Boolean = false,
    val preferZeroShutterLag: Boolean = true,
) {
    companion object {
        fun fromMap(map: Map<*, *>): LivePhotoConfig {
            fun readInt(key: String, fallback: Int): Int {
                val value = map[key]
                return when (value) {
                    is Int -> value
                    is Number -> value.toInt()
                    else -> value?.toString()?.toIntOrNull() ?: fallback
                }
            }

            fun readBoolean(key: String, fallback: Boolean): Boolean {
                val value = map[key]
                return when (value) {
                    is Boolean -> value
                    is Number -> value.toInt() != 0
                    else -> value?.toString()?.equals("true", ignoreCase = true) ?: fallback
                }
            }

            return LivePhotoConfig(
                lensFacing = map["lensFacing"]?.toString() ?: "back",
                preCaptureDurationMs = readInt("preCaptureDurationMs", 2000),
                targetClipDurationMs = readInt("targetClipDurationMs", 2000),
                sessionTimeoutMs = readInt("sessionTimeoutMs", 45_000),
                preferredQuality = map["preferredQuality"]?.toString() ?: "HD",
                muteVideo = readBoolean("muteVideo", false),
                preferZeroShutterLag = readBoolean("preferZeroShutterLag", true),
            )
        }
    }
}
