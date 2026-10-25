package app.sidequest.livephoto

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class LivePhotoPreviewFactory(
    private val sessionLookup: (String) -> LivePhotoCameraSession?,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val creationParams = args as? Map<*, *> ?: emptyMap<String, Any?>()
        val sessionId = creationParams["sessionId"]?.toString().orEmpty()
        return LivePhotoPreviewView(
            context = context,
            session = sessionLookup(sessionId),
        )
    }
}
