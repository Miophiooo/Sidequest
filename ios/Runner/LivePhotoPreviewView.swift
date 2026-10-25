import AVFoundation
import Flutter
import UIKit

/// UIView whose backing layer is an `AVCaptureVideoPreviewLayer`. Using a
/// custom `layerClass` is what makes the preview layer track every layout
/// pass — Flutter resizes platform views by changing the UIView's bounds, and
/// a plain sublayer wouldn't follow.
final class LivePhotoPreviewContainer: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// Hosts the `AVCaptureVideoPreviewLayer` for a live photo session. Looked
/// up from Flutter via the platform view type `sidequest/live_photo/preview`.
final class LivePhotoPreviewView: NSObject, FlutterPlatformView {
    private let container: LivePhotoPreviewContainer

    init(frame: CGRect, sessionId: String, fit: String, sessionLookup: (String) -> LivePhotoCameraSession?) {
        container = LivePhotoPreviewContainer(frame: frame)
        super.init()
        container.backgroundColor = .black
        // Always portrait — the app is locked in portrait orientation.
        if container.previewLayer.connection?.isVideoOrientationSupported == true {
            container.previewLayer.connection?.videoOrientation = .portrait
        }
        container.previewLayer.videoGravity = (fit == "contain") ? .resizeAspect : .resizeAspectFill

        if let session = sessionLookup(sessionId) {
            container.previewLayer.session = session.avCaptureSession
        }
    }

    func view() -> UIView { container }
}

final class LivePhotoPreviewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger
    private let sessionLookup: (String) -> LivePhotoCameraSession?

    init(messenger: FlutterBinaryMessenger, sessionLookup: @escaping (String) -> LivePhotoCameraSession?) {
        self.messenger = messenger
        self.sessionLookup = sessionLookup
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        let params = (args as? [String: Any]) ?? [:]
        let sessionId = (params["sessionId"] as? String) ?? ""
        let fit = (params["fit"] as? String) ?? "cover"
        return LivePhotoPreviewView(frame: frame, sessionId: sessionId, fit: fit, sessionLookup: sessionLookup)
    }
}
