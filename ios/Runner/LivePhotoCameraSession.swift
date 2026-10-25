import AVFoundation
import Foundation
import UIKit

/// Wraps a single AVCaptureSession configured for Live Photo capture. The
/// public surface mirrors the Android `LivePhotoCameraSession` so the Dart
/// platform layer stays platform-agnostic.
///
/// One session = one preview + one rolling AVCapturePhotoOutput. The session
/// is owned by `LivePhotoPlugin` and disposed when Flutter calls `dispose`.
final class LivePhotoCameraSession: NSObject {
    typealias EventEmitter = ([String: Any?]) -> Void

    let id: String
    private let config: [String: Any]
    private let emit: EventEmitter

    private let sessionQueue = DispatchQueue(label: "sidequest.livephoto.session")
    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?

    private var activeCaptureDelegate: LivePhotoCaptureDelegate?
    private var isConfigured = false
    private var isDisposed = false
    private var flashMode: AVCaptureDevice.FlashMode = .off

    init(id: String, config: [String: Any], emit: @escaping EventEmitter) {
        self.id = id
        self.config = config
        self.emit = emit
        super.init()
        emit(makeEvent(state: "initializing"))
    }

    var avCaptureSession: AVCaptureSession { captureSession }

    func capabilities() -> [String: Any] {
        // `isLivePhotoCaptureSupported` is only meaningful once the output has
        // been added to a configured session. Before that it returns false on
        // every device. Reporting based on platform availability (iOS 9.1+,
        // every shipping iPhone) keeps the Dart side from short-circuiting
        // initialization — actual unsupported scenarios surface as a
        // `unsupported` error from `capture()`.
        return [
            "isSupported": true,
            "supportsFrontCamera": true,
            "supportsZeroShutterLag": true,
            "supportedQualities": ["HD"],
        ]
    }

    // MARK: - Lifecycle

    func start(result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isDisposed {
                DispatchQueue.main.async {
                    result(FlutterError(code: "sessionMissing", message: "Session has been disposed.", details: nil))
                }
                return
            }

            do {
                if !self.isConfigured {
                    try self.configureSession()
                    self.isConfigured = true
                }
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                self.emit(self.makeEvent(state: "ready"))
                DispatchQueue.main.async { result(nil) }
            } catch let error as LivePhotoConfigError {
                self.emit(self.makeEvent(state: "error", errorCode: error.code, message: error.message))
                DispatchQueue.main.async {
                    result(FlutterError(code: error.code, message: error.message, details: nil))
                }
            } catch {
                let message = error.localizedDescription
                self.emit(self.makeEvent(state: "error", errorCode: "unknown", message: message))
                DispatchQueue.main.async {
                    result(FlutterError(code: "unknown", message: message, details: nil))
                }
            }
        }
    }

    func setFlashMode(_ mode: String) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            switch mode.lowercased() {
            case "on":
                self.flashMode = .on
            case "auto":
                self.flashMode = .auto
            default:
                self.flashMode = .off
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            self.emit(self.makeEvent(state: "stopped"))
        }
    }

    func dispose() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.isDisposed = true
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            self.captureSession.beginConfiguration()
            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }
            for output in self.captureSession.outputs {
                self.captureSession.removeOutput(output)
            }
            self.captureSession.commitConfiguration()
            self.activeCaptureDelegate = nil
        }
    }

    // MARK: - Capture

    func capture(result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isDisposed {
                DispatchQueue.main.async {
                    result(FlutterError(code: "sessionMissing", message: "Session has been disposed.", details: nil))
                }
                return
            }
            if self.activeCaptureDelegate != nil {
                DispatchQueue.main.async {
                    result(FlutterError(code: "captureInProgress", message: "A capture is already in progress.", details: nil))
                }
                return
            }
            guard self.captureSession.isRunning else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "sessionMissing", message: "Session is not running.", details: nil))
                }
                return
            }
            guard self.photoOutput.isLivePhotoCaptureSupported,
                  self.photoOutput.isLivePhotoCaptureEnabled else {
                // Either the device truly doesn't support live photo, or the
                // post-commit enable in `configureSession` didn't take. Setting
                // `livePhotoMovieFileURL` on an output where capture isn't
                // enabled would throw NSInvalidArgumentException at runtime.
                DispatchQueue.main.async {
                    result(FlutterError(code: "unsupported", message: "Live photo capture is not enabled on this device.", details: nil))
                }
                return
            }

            // Each capture requires a unique AVCapturePhotoSettings instance.
            let settings = AVCapturePhotoSettings()
            settings.isHighResolutionPhotoEnabled = true
            if self.photoOutput.supportedFlashModes.contains(self.flashMode) {
                settings.flashMode = self.flashMode
            }
            let movieURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sidequest_live_\(UUID().uuidString).mov")
            settings.livePhotoMovieFileURL = movieURL

            // Match the preview's orientation so the still + clip match what
            // the user saw on screen. The app is portrait-only.
            if let connection = self.photoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                if let input = self.videoDeviceInput,
                   input.device.position == .front,
                   connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }

            self.emit(self.makeEvent(state: "capturing"))

            let delegate = LivePhotoCaptureDelegate(sessionId: self.id) { [weak self] payload, error in
                guard let self = self else { return }
                self.sessionQueue.async {
                    self.activeCaptureDelegate = nil
                }
                if let error = error {
                    let code = error.code.isEmpty ? "photoCaptureFailed" : error.code
                    self.emit(self.makeEvent(state: "error", errorCode: code, message: error.message))
                    DispatchQueue.main.async {
                        result(FlutterError(code: code, message: error.message, details: nil))
                    }
                    return
                }
                self.emit(self.makeEvent(state: "ready"))
                DispatchQueue.main.async { result(payload) }
            }
            self.activeCaptureDelegate = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - Session configuration

    private func configureSession() throws {
        captureSession.beginConfiguration()
        var configurationCommitted = false
        defer {
            if !configurationCommitted {
                captureSession.commitConfiguration()
            }
        }

        captureSession.sessionPreset = .photo

        // Video input — back camera by default, switch to front if requested.
        let lensFacing = (config["lensFacing"] as? String) ?? "back"
        let position: AVCaptureDevice.Position = lensFacing == "front" ? .front : .back
        guard let device = bestCameraDevice(for: position) ?? bestCameraDevice(for: .back) else {
            throw LivePhotoConfigError(code: "unsupported", message: "No suitable camera device available.")
        }
        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw LivePhotoConfigError(code: "unsupported", message: "Could not open camera device: \(error.localizedDescription)")
        }
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
            videoDeviceInput = videoInput
        } else {
            throw LivePhotoConfigError(code: "unsupported", message: "Could not add camera input to the session.")
        }

        // Audio input is best-effort: when the user grants mic, the resulting
        // Live Photo movie includes an audio track that we later analyse for
        // peak loudness. When denied, the still + silent clip pair still works.
        let muteVideo = (config["muteVideo"] as? Bool) ?? true
        if !muteVideo {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if micStatus == .authorized, let micDevice = AVCaptureDevice.default(for: .audio) {
                if let micInput = try? AVCaptureDeviceInput(device: micDevice),
                   captureSession.canAddInput(micInput) {
                    captureSession.addInput(micInput)
                }
            }
        }

        guard captureSession.canAddOutput(photoOutput) else {
            throw LivePhotoConfigError(code: "unsupported", message: "Could not add photo output to the session.")
        }
        captureSession.addOutput(photoOutput)
        photoOutput.isHighResolutionCaptureEnabled = true

        captureSession.commitConfiguration()
        configurationCommitted = true

        // Live Photo enable MUST happen after the session has been committed.
        // Before commit, `isLivePhotoCaptureSupported` returns false on newer
        // iOS versions because the active format isn't yet resolved — which
        // silently leaves `isLivePhotoCaptureEnabled = false` and the system
        // produces only the still without the movie pair.
        if photoOutput.isLivePhotoCaptureSupported {
            captureSession.beginConfiguration()
            photoOutput.isLivePhotoCaptureEnabled = true
            captureSession.commitConfiguration()
        }
    }

    private func bestCameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }

    private func makeEvent(state: String, errorCode: String? = nil, message: String? = nil) -> [String: Any?] {
        return [
            "sessionId": id,
            "state": state,
            "errorCode": errorCode,
            "message": message,
        ]
    }
}

private struct LivePhotoConfigError: Error {
    let code: String
    let message: String
}

/// Captures the still + Live Photo movie pair for a single shutter press.
private final class LivePhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    struct DelegateError {
        let code: String
        let message: String
    }

    private let sessionId: String
    private let completion: ([String: Any]?, DelegateError?) -> Void

    private var photoData: Data?
    private var photoCapturedAtMs: Int64 = 0
    private var movieURL: URL?
    private var movieDurationMs: Int64 = 0
    private var movieDimensions: CGSize = .zero
    private var didReportResult = false

    init(sessionId: String, completion: @escaping ([String: Any]?, DelegateError?) -> Void) {
        self.sessionId = sessionId
        self.completion = completion
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            finish(error: DelegateError(code: "photoCaptureFailed", message: error.localizedDescription))
            return
        }
        photoData = photo.fileDataRepresentation()
        photoCapturedAtMs = Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error = error {
            finish(error: DelegateError(code: "clipGenerationFailed", message: error.localizedDescription))
            return
        }
        movieURL = outputFileURL
        movieDurationMs = Int64(CMTimeGetSeconds(duration) * 1000.0)
        let size = resolvedSettings.livePhotoMovieDimensions
        movieDimensions = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error {
            finish(error: DelegateError(code: "photoCaptureFailed", message: error.localizedDescription))
            return
        }
        guard let photoData = photoData else {
            finish(error: DelegateError(code: "photoCaptureFailed", message: "Photo data is missing after capture."))
            return
        }
        guard let movieURL = movieURL else {
            finish(error: DelegateError(code: "clipGenerationFailed", message: "Live photo movie was not produced."))
            return
        }

        // Persist the still next to the movie so both files survive past this
        // method returning. The Dart side will pick them up by path.
        let photoURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sidequest_live_\(UUID().uuidString).jpg")
        do {
            try photoData.write(to: photoURL)
        } catch {
            finish(error: DelegateError(code: "photoCaptureFailed", message: "Could not write still file: \(error.localizedDescription)"))
            return
        }

        let audioPeakDbfs = LivePhotoAudioAnalysis.measurePeakDbfs(url: movieURL)

        // The original movie keeps the full sensor resolution (3–7 MB for
        // ~2 s); upload a small MP4 instead and keep the original only if
        // re-encoding fails.
        LivePhotoClipCompressor.compress(movieURL) { [self] compressedURL, compressedSize in
            var clipURL = movieURL
            var clipSize = movieDimensions
            if let compressedURL = compressedURL {
                try? FileManager.default.removeItem(at: movieURL)
                clipURL = compressedURL
                if let compressedSize = compressedSize { clipSize = compressedSize }
            }

            let payload: [String: Any] = [
                "sessionId": sessionId,
                "photoPath": photoURL.path,
                "clipPath": clipURL.path,
                "photoTakenAtEpochMs": photoCapturedAtMs,
                "clipStartEpochMs": photoCapturedAtMs - movieDurationMs / 2,
                "clipDurationMs": movieDurationMs,
                "videoWidth": Int(clipSize.width),
                "videoHeight": Int(clipSize.height),
                "videoFps": 30,
                "didFallbackToLatencyMode": false,
                "isStillOnlyFallback": false,
                "audioPeakDbfs": audioPeakDbfs as Any,
            ]
            finish(payload: payload)
        }
    }

    private func finish(payload: [String: Any]? = nil, error: DelegateError? = nil) {
        if didReportResult { return }
        didReportResult = true
        completion(payload, error)
    }
}

/// Re-encodes a Live Photo movie to a 960x540 H.264 MP4 (~0.5 MB for a ~2 s
/// clip). The system export keeps orientation and audio. Calls back with nil
/// on any failure so the caller can fall back to the original file.
private enum LivePhotoClipCompressor {
    static func compress(_ source: URL, completion: @escaping (URL?, CGSize?) -> Void) {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset960x540
        ), export.supportedFileTypes.contains(.mp4) else {
            completion(nil, nil)
            return
        }

        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sidequest_live_\(UUID().uuidString).mp4")
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.exportAsynchronously {
            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: output)
                completion(nil, nil)
                return
            }
            completion(output, LivePhotoClipCompressor.displaySize(of: output))
        }
    }

    /// Size of the first video track as shown (rotation applied).
    private static func displaySize(of url: URL) -> CGSize? {
        guard let track = AVURLAsset(url: url).tracks(withMediaType: .video).first else {
            return nil
        }
        let size = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }
}
