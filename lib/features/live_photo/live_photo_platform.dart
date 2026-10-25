import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'live_photo_models.dart';

class LivePhotoPlatform {
  static const MethodChannel _methodChannel = MethodChannel(
    'sidequest/live_photo/methods',
  );
  static const EventChannel _eventChannel = EventChannel(
    'sidequest/live_photo/events',
  );

  static Stream<LivePhotoSessionEvent>? _broadcastEvents;

  const LivePhotoPlatform();

  Stream<LivePhotoSessionEvent> sessionEvents(String sessionId) {
    _broadcastEvents ??= _eventChannel
        .receiveBroadcastStream()
        .map<Map<Object?, Object?>>((dynamic event) {
          return Map<Object?, Object?>.from(
            (event as Map?) ?? const <Object?, Object?>{},
          );
        })
        .map(LivePhotoSessionEvent.fromMap)
        .asBroadcastStream();

    return _broadcastEvents!.where((event) => event.sessionId == sessionId);
  }

  Future<bool> ensurePermissions() async {
    if (!_isSupported) return false;
    try {
      final granted = await _methodChannel.invokeMethod<bool>(
        'ensurePermissions',
      );
      return granted == true;
    } on PlatformException catch (error) {
      throw _mapException(error);
    }
  }

  Future<LivePhotoSessionHandle> initializeLivePhotoCamera({
    LivePhotoSessionConfig config = const LivePhotoSessionConfig(),
  }) async {
    if (!_isSupported) {
      throw const LivePhotoPlatformException(
        code: LivePhotoErrorCode.unsupported,
        message: 'Live photo capture is only supported on Android and iOS.',
      );
    }

    try {
      final payload = await _methodChannel.invokeMethod<Map<Object?, Object?>>(
        'initializeLivePhotoCamera',
        <String, Object?>{'config': config.toMap()},
      );
      return LivePhotoSessionHandle.fromMap(
        payload ?? const <Object?, Object?>{},
      );
    } on PlatformException catch (error) {
      throw _mapException(error);
    }
  }

  Future<void> startSession(String sessionId) async {
    await _invokeVoid('startSession', <String, Object?>{
      'sessionId': sessionId,
    });
  }

  Future<void> stopSession(String sessionId) async {
    await _invokeVoid('stopSession', <String, Object?>{'sessionId': sessionId});
  }

  Future<LivePhotoCaptureResult> captureLivePhoto(String sessionId) async {
    try {
      final payload = await _methodChannel.invokeMethod<Map<Object?, Object?>>(
        'captureLivePhoto',
        <String, Object?>{'sessionId': sessionId},
      );
      return LivePhotoCaptureResult.fromMap(
        payload ?? const <Object?, Object?>{},
      );
    } on PlatformException catch (error) {
      throw _mapException(error);
    }
  }

  Future<void> setFlashMode(String sessionId, String mode) async {
    await _invokeVoid('setFlashMode', <String, Object?>{
      'sessionId': sessionId,
      'mode': mode,
    });
  }

  Future<void> dispose(String sessionId) async {
    await _invokeVoid('dispose', <String, Object?>{'sessionId': sessionId});
  }

  Future<void> _invokeVoid(
    String method,
    Map<String, Object?> arguments,
  ) async {
    if (!_isSupported) {
      throw const LivePhotoPlatformException(
        code: LivePhotoErrorCode.unsupported,
        message: 'Live photo capture is only supported on Android and iOS.',
      );
    }

    try {
      await _methodChannel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw _mapException(error);
    }
  }

  LivePhotoPlatformException _mapException(PlatformException error) {
    final rawCode = error.code.trim();
    final mappedCode = LivePhotoErrorCode.values.firstWhere(
      (value) => value.name == rawCode,
      orElse: () => LivePhotoErrorCode.unknown,
    );
    return LivePhotoPlatformException(
      code: mappedCode,
      message: error.message ?? 'Live photo platform call failed.',
      details: error.details,
    );
  }

  bool get _isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }
}
