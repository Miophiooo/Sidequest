package app.sidequest.livephoto

import android.content.Context
import android.view.View
import androidx.camera.view.PreviewView
import io.flutter.plugin.platform.PlatformView

class LivePhotoPreviewView(
    context: Context,
    private val session: LivePhotoCameraSession?,
) : PlatformView {
    private val previewView =
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }

    init {
        session?.attachPreview(previewView)
    }

    override fun getView(): View = previewView

    override fun dispose() {
        session?.detachPreview(previewView)
    }
}
