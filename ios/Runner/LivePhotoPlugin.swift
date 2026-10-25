import AVFoundation
import Flutter
import UIKit

/// iOS counterpart to the Android `LivePhotoPlugin`. Wires up the method
/// channel (`sidequest/live_photo/methods`), the event channel
/// (`sidequest/live_photo/events`) and the platform view factory used by
/// `LivePhotoPreview` on the Dart side.
final class LivePhotoPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    static let methodChannelName = "sidequest/live_photo/methods"
    static let eventChannelName = "sidequest/live_photo/events"
    static let previewViewType = "sidequest/live_photo/preview"

    private var sessions: [String: LivePhotoCameraSession] = [:]
    private var eventSink: FlutterEventSink?

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = LivePhotoPlugin()
        let methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: eventChannelName, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)

        let factory = LivePhotoPreviewFactory(messenger: registrar.messenger()) { [weak instance] sessionId in
            return instance?.sessions[sessionId]
        }
        registrar.register(factory, withId: previewViewType)
    }

    // MARK: - FlutterPlugin

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "ensurePermissions":
            ensurePermissions(result: result)
        case "initializeLivePhotoCamera":
            initializeSession(call: call, result: result)
        case "startSession":
            withSession(call: call, result: result) { $0.start(result: result) }
        case "stopSession":
            withSession(call: call, result: result) { session in
                session.stop()
                result(nil)
            }
        case "captureLivePhoto":
            withSession(call: call, result: result) { $0.capture(result: result) }
        case "setFlashMode":
            withSession(call: call, result: result) { session in
                let mode = (call.arguments as? [String: Any])?["mode"] as? String ?? "off"
                session.setFlashMode(mode)
                result(nil)
            }
        case "dispose":
            disposeSession(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Internals

    private func emit(_ event: [String: Any?]) {
        // FlutterEventSink doesn't tolerate nil values inside the map — strip
        // them out so the Dart side receives clean Maps.
        let cleaned = event.compactMapValues { $0 }
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(cleaned)
        }
    }

    private func ensurePermissions(result: @escaping FlutterResult) {
        // Camera is the hard requirement; mic is best-effort so denying it
        // still lets the user keep taking live photos (just silent ones).
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

        func resolveMic(cameraGranted: Bool) {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if micStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { result(cameraGranted) }
                }
            } else {
                DispatchQueue.main.async { result(cameraGranted) }
            }
        }

        switch cameraStatus {
        case .authorized:
            resolveMic(cameraGranted: true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                resolveMic(cameraGranted: granted)
            }
        case .denied, .restricted:
            DispatchQueue.main.async { result(false) }
        @unknown default:
            DispatchQueue.main.async { result(false) }
        }
    }

    private func initializeSession(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let config = (args["config"] as? [String: Any]) ?? [:]
        let sessionId = UUID().uuidString
        let session = LivePhotoCameraSession(id: sessionId, config: config) { [weak self] event in
            self?.emit(event)
        }
        sessions[sessionId] = session
        result([
            "sessionId": sessionId,
            "capabilities": session.capabilities(),
        ])
    }

    private func disposeSession(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let id = (call.arguments as? [String: Any])?["sessionId"] as? String ?? ""
        guard !id.isEmpty else {
            result(FlutterError(code: "sessionMissing", message: "Missing live photo session id.", details: nil))
            return
        }
        sessions.removeValue(forKey: id)?.dispose()
        result(nil)
    }

    private func withSession(
        call: FlutterMethodCall,
        result: @escaping FlutterResult,
        block: (LivePhotoCameraSession) -> Void
    ) {
        let id = (call.arguments as? [String: Any])?["sessionId"] as? String ?? ""
        guard !id.isEmpty else {
            result(FlutterError(code: "sessionMissing", message: "Missing live photo session id.", details: nil))
            return
        }
        guard let session = sessions[id] else {
            result(FlutterError(code: "sessionMissing", message: "Live photo session not found.", details: nil))
            return
        }
        block(session)
    }
}
