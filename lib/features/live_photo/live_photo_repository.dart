import 'package:supabase_flutter/supabase_flutter.dart';

import 'live_photo_models.dart';
import 'live_photo_platform.dart';
import 'live_photo_upload_service.dart';

class LivePhotoRepository {
  final LivePhotoPlatform platform;
  final LivePhotoUploadService uploadService;

  LivePhotoRepository({
    LivePhotoPlatform? platform,
    LivePhotoUploadService? uploadService,
    SupabaseClient? client,
  }) : platform = platform ?? const LivePhotoPlatform(),
       uploadService =
           uploadService ??
           LivePhotoUploadService(client: client ?? Supabase.instance.client);

  Stream<LivePhotoSessionEvent> sessionEvents(String sessionId) {
    return platform.sessionEvents(sessionId);
  }

  Future<bool> ensurePermissions() => platform.ensurePermissions();

  Future<LivePhotoSessionHandle> initializeSession({
    LivePhotoSessionConfig config = const LivePhotoSessionConfig(),
  }) {
    return platform.initializeLivePhotoCamera(config: config);
  }

  Future<void> startSession(String sessionId) =>
      platform.startSession(sessionId);

  Future<void> stopSession(String sessionId) => platform.stopSession(sessionId);

  Future<LivePhotoCaptureResult> capture(String sessionId) {
    return platform.captureLivePhoto(sessionId);
  }

  Future<void> setFlashMode(String sessionId, String mode) =>
      platform.setFlashMode(sessionId, mode);

  Future<void> disposeSession(String sessionId) => platform.dispose(sessionId);

  Future<LivePhotoPostCommitResult> uploadCapture(
    LivePhotoPostUploadRequest request,
  ) {
    return uploadService.upload(request);
  }
}
