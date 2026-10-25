import 'package:flutter/foundation.dart';

enum LivePhotoErrorCode {
  unsupported,
  permissionDenied,
  sessionMissing,
  sessionAlreadyRunning,
  sessionTimedOut,
  captureInProgress,
  photoCaptureFailed,
  clipGenerationFailed,
  lowStorage,
  canceled,
  unknown,
}

enum LivePhotoSessionState {
  idle,
  initializing,
  ready,
  buffering,
  capturing,
  stopped,
  error,
}

@immutable
class LivePhotoCapabilities {
  final bool isSupported;
  final bool supportsFrontCamera;
  final bool supportsZeroShutterLag;
  final List<String> supportedQualities;

  const LivePhotoCapabilities({
    required this.isSupported,
    required this.supportsFrontCamera,
    required this.supportsZeroShutterLag,
    required this.supportedQualities,
  });

  factory LivePhotoCapabilities.fromMap(Map<Object?, Object?> map) {
    return LivePhotoCapabilities(
      isSupported: map['isSupported'] == true,
      supportsFrontCamera: map['supportsFrontCamera'] == true,
      supportsZeroShutterLag: map['supportsZeroShutterLag'] == true,
      supportedQualities: ((map['supportedQualities'] as List?) ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'isSupported': isSupported,
      'supportsFrontCamera': supportsFrontCamera,
      'supportsZeroShutterLag': supportsZeroShutterLag,
      'supportedQualities': supportedQualities,
    };
  }
}

@immutable
class LivePhotoSessionConfig {
  final String lensFacing;
  final int preCaptureDurationMs;
  final int targetClipDurationMs;
  final int sessionTimeoutMs;
  final String preferredQuality;
  final bool muteVideo;
  final bool preferZeroShutterLag;

  const LivePhotoSessionConfig({
    this.lensFacing = 'back',
    this.preCaptureDurationMs = 2000,
    this.targetClipDurationMs = 2000,
    this.sessionTimeoutMs = 45000,
    this.preferredQuality = 'HD',
    this.muteVideo = false,
    this.preferZeroShutterLag = true,
  });

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'lensFacing': lensFacing,
      'preCaptureDurationMs': preCaptureDurationMs,
      'targetClipDurationMs': targetClipDurationMs,
      'sessionTimeoutMs': sessionTimeoutMs,
      'preferredQuality': preferredQuality,
      'muteVideo': muteVideo,
      'preferZeroShutterLag': preferZeroShutterLag,
    };
  }
}

@immutable
class LivePhotoSessionHandle {
  final String sessionId;
  final LivePhotoCapabilities capabilities;

  const LivePhotoSessionHandle({
    required this.sessionId,
    required this.capabilities,
  });

  factory LivePhotoSessionHandle.fromMap(Map<Object?, Object?> map) {
    return LivePhotoSessionHandle(
      sessionId: (map['sessionId'] ?? '').toString(),
      capabilities: LivePhotoCapabilities.fromMap(
        Map<Object?, Object?>.from(
          (map['capabilities'] as Map?) ?? const <Object?, Object?>{},
        ),
      ),
    );
  }
}

@immutable
class LivePhotoSessionEvent {
  final String sessionId;
  final LivePhotoSessionState state;
  final String? message;
  final LivePhotoErrorCode? errorCode;

  const LivePhotoSessionEvent({
    required this.sessionId,
    required this.state,
    this.message,
    this.errorCode,
  });

  factory LivePhotoSessionEvent.fromMap(Map<Object?, Object?> map) {
    final rawState = (map['state'] ?? 'idle').toString();
    final rawErrorCode = map['errorCode']?.toString();
    return LivePhotoSessionEvent(
      sessionId: (map['sessionId'] ?? '').toString(),
      state: LivePhotoSessionState.values.firstWhere(
        (value) => value.name == rawState,
        orElse: () => LivePhotoSessionState.idle,
      ),
      message: map['message']?.toString(),
      errorCode: rawErrorCode == null
          ? null
          : LivePhotoErrorCode.values.firstWhere(
              (value) => value.name == rawErrorCode,
              orElse: () => LivePhotoErrorCode.unknown,
            ),
    );
  }
}

@immutable
class LivePhotoCaptureResult {
  final String sessionId;
  final String photoPath;
  final String clipPath;
  final int photoTakenAtEpochMs;
  final int clipStartEpochMs;
  final int clipDurationMs;
  final int videoWidth;
  final int videoHeight;
  final int videoFps;
  final bool didFallbackToLatencyMode;
  final bool isStillOnlyFallback;
  final String? fallbackReason;
  // Peak loudness in dBFS over the captured clip. Null when the rolling
  // recording had no audio track (mic denied / muteVideo). Used to decide
  // whether to mark the resulting post as having meaningful audio.
  final double? audioPeakDbfs;

  const LivePhotoCaptureResult({
    required this.sessionId,
    required this.photoPath,
    required this.clipPath,
    required this.photoTakenAtEpochMs,
    required this.clipStartEpochMs,
    required this.clipDurationMs,
    required this.videoWidth,
    required this.videoHeight,
    required this.videoFps,
    required this.didFallbackToLatencyMode,
    this.isStillOnlyFallback = false,
    this.fallbackReason,
    this.audioPeakDbfs,
  });

  factory LivePhotoCaptureResult.fromMap(Map<Object?, Object?> map) {
    int asInt(Object? value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    double? asDoubleOrNull(Object? value) {
      if (value == null) return null;
      if (value is double) return value;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

    return LivePhotoCaptureResult(
      sessionId: (map['sessionId'] ?? '').toString(),
      photoPath: (map['photoPath'] ?? '').toString(),
      clipPath: (map['clipPath'] ?? '').toString(),
      photoTakenAtEpochMs: asInt(map['photoTakenAtEpochMs']),
      clipStartEpochMs: asInt(map['clipStartEpochMs']),
      clipDurationMs: asInt(map['clipDurationMs']),
      videoWidth: asInt(map['videoWidth']),
      videoHeight: asInt(map['videoHeight']),
      videoFps: asInt(map['videoFps']),
      didFallbackToLatencyMode: map['didFallbackToLatencyMode'] == true,
      isStillOnlyFallback: map['isStillOnlyFallback'] == true,
      fallbackReason: map['fallbackReason']?.toString(),
      audioPeakDbfs: asDoubleOrNull(map['audioPeakDbfs']),
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'sessionId': sessionId,
      'photoPath': photoPath,
      'clipPath': clipPath,
      'photoTakenAtEpochMs': photoTakenAtEpochMs,
      'clipStartEpochMs': clipStartEpochMs,
      'clipDurationMs': clipDurationMs,
      'videoWidth': videoWidth,
      'videoHeight': videoHeight,
      'videoFps': videoFps,
      'didFallbackToLatencyMode': didFallbackToLatencyMode,
      'isStillOnlyFallback': isStillOnlyFallback,
      'fallbackReason': fallbackReason,
      'audioPeakDbfs': audioPeakDbfs,
    };
  }

  bool get hasPlayableClip =>
      clipPath.trim().isNotEmpty && !isStillOnlyFallback;
}

@immutable
class LivePhotoPostAttachment {
  final bool isLivePhoto;
  final String mediaKind;
  final String? clipUrl;
  final int clipDurationMs;
  final int preCaptureDurationMs;
  // Whether the recorded audio peak fell below the inclusion threshold at
  // upload time. True = effectively silent, render the feed mute icon; false
  // = audible, render the sound icon and allow unmute on tap.
  final bool liveMuted;

  const LivePhotoPostAttachment({
    required this.isLivePhoto,
    required this.mediaKind,
    required this.clipUrl,
    required this.clipDurationMs,
    required this.preCaptureDurationMs,
    required this.liveMuted,
  });

  static int _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static bool _readBool(Object? value, {bool fallback = true}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final s = value?.toString().toLowerCase();
    if (s == 'true' || s == 't' || s == '1') return true;
    if (s == 'false' || s == 'f' || s == '0') return false;
    return fallback;
  }

  factory LivePhotoPostAttachment.fromPostMap(Map<String, dynamic> map) {
    final mediaKind = (map['media_kind'] ?? 'photo').toString().trim();
    final clipUrl = (map['live_photo_clip_url'] ?? '').toString().trim();
    final isLivePhoto =
        mediaKind == 'live_photo' ||
        map['is_live_photo'] == true ||
        clipUrl.isNotEmpty;
    return LivePhotoPostAttachment(
      isLivePhoto: isLivePhoto,
      mediaKind: mediaKind.isEmpty ? 'photo' : mediaKind,
      clipUrl: clipUrl.isEmpty ? null : clipUrl,
      clipDurationMs: _readInt(map['live_photo_duration_ms']),
      preCaptureDurationMs: _readInt(map['live_photo_pre_capture_ms']),
      liveMuted: _readBool(map['live_photo_muted'], fallback: true),
    );
  }
}

@immutable
class LivePhotoPostUploadRequest {
  final LivePhotoCaptureResult captureResult;
  final bool isPublic;
  final String? postDescription;
  final bool deleteLocalFilesOnSuccess;

  const LivePhotoPostUploadRequest({
    required this.captureResult,
    required this.isPublic,
    this.postDescription,
    this.deleteLocalFilesOnSuccess = true,
  });
}

@immutable
class LivePhotoPostCommitResult {
  final String photoId;
  final bool isLate;
  final bool descriptionPersisted;
  final int streakCount;
  final String stillUrl;
  final String liveClipUrl;

  const LivePhotoPostCommitResult({
    required this.photoId,
    required this.isLate,
    required this.descriptionPersisted,
    required this.streakCount,
    required this.stillUrl,
    required this.liveClipUrl,
  });
}

class LivePhotoPlatformException implements Exception {
  final LivePhotoErrorCode code;
  final String message;
  final Object? details;

  const LivePhotoPlatformException({
    required this.code,
    required this.message,
    this.details,
  });

  @override
  String toString() {
    return 'LivePhotoPlatformException(code: ${code.name}, message: $message, details: $details)';
  }
}
