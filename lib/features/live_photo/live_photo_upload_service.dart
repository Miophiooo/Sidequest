import 'dart:io';

import 'package:nummwe3/daily_challenges.dart' as challenge_time;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../analytics_service.dart';
import '../daily_quest/post_streak.dart';
import '../media/post_media.dart';
import '../../core/app_logger.dart';
import '../../image_compression.dart';
import '../../image_validation.dart';
import '../../mentions.dart';
import '../../shared.dart';
import 'live_photo_models.dart';

class LivePhotoUploadService {
  final SupabaseClient client;
  static const String _mediaBucket = 'photos';
  // Peak loudness above this is considered "meaningful audio" for the post.
  // Tuned roughly for normal indoor speech (-30 to -40 dBFS) — picks up laughs
  // and chatter, ignores idle room tone. Adjust based on real-world testing.
  static const double _audioInclusionThresholdDbfs = -35.0;

  const LivePhotoUploadService({required this.client});

  Future<LivePhotoPostCommitResult> upload(
    LivePhotoPostUploadRequest request,
  ) async {
    final capture = request.captureResult;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      throw StateError(
        'No authenticated user available for live photo upload.',
      );
    }

    final stillValidation = await validateImageFile(capture.photoPath);
    if (!stillValidation.isValid) {
      throw StateError('Live photo still image failed validation.');
    }

    final clipFile = File(capture.clipPath);
    if (!await clipFile.exists()) {
      throw StateError('Live photo clip file does not exist.');
    }

    final clipBytes = await clipFile.length();
    if (clipBytes <= 0) {
      throw StateError('Live photo clip file is empty.');
    }

    final normalizedPostDescription = (request.postDescription ?? '').trim();
    final nowLocal = DateTime.now();
    DateTime activeStartLocal = challengeStartLocal(nowLocal);
    if (nowLocal.isBefore(activeStartLocal)) {
      activeStartLocal = challengeStartLocal(
        nowLocal.subtract(const Duration(days: 1)),
      );
    }
    final activeEndLocal = challengeEndLocal(activeStartLocal);
    // The server decides lateness on insert (guard_photo_timing).
    var effectiveIsLate = nowLocal.isAfter(activeEndLocal);
    final createdAtIso = DateTime.now().toUtc().toIso8601String();

    final capturePrefix = 'live_${DateTime.now().millisecondsSinceEpoch}';
    final stillStoragePath = '$userId/live_photo/$capturePrefix.jpg';
    final clipStoragePath = '$userId/live_photo/$capturePrefix.mp4';

    String? insertedPhotoId;
    var descriptionPersisted = normalizedPostDescription.isEmpty;
    var resultingStreakCount = 0;
    var stillUploaded = false;
    var clipUploaded = false;

    try {
      // Compress the still so the detail-view download/decode isn't a 4-6 MB
      // raw phone capture. Normal feed photos already go through this; live
      // photo stills used to skip it, which made fullscreen preview crawl.
      final compressedStill = await compressPhotoForUpload(capture.photoPath);
      await client.storage
          .from(_mediaBucket)
          .upload(stillStoragePath, compressedStill);
      stillUploaded = true;
      final thumbUrl = await uploadPostThumbnail(
        client: client,
        sourcePath: compressedStill.path,
        fullStoragePath: stillStoragePath,
      );

      await client.storage.from(_mediaBucket).upload(clipStoragePath, clipFile);
      clipUploaded = true;

      final stillUrl = client.storage
          .from(_mediaBucket)
          .getPublicUrl(stillStoragePath);
      final clipUrl = client.storage
          .from(_mediaBucket)
          .getPublicUrl(clipStoragePath);

      // Audio inclusion gate: if the recorded clip's peak loudness clears
      // the threshold, mark the post as un-muted so the feed renders the
      // sound icon and lets the viewer unmute. Below threshold (or no audio
      // track at all) → muted.
      final peakDbfs = capture.audioPeakDbfs;
      final hasAudibleAudio =
          peakDbfs != null && peakDbfs > _audioInclusionThresholdDbfs;

      final basePayload = <String, dynamic>{
        'user_id': userId,
        'url': stillUrl,
        'thumb_url': ?thumbUrl,
        'created_at': createdAtIso,
        'is_public': request.isPublic,
        'is_challenge_photo': false,
        'challenge_id': null,
        'is_late': effectiveIsLate,
        'media_kind': 'live_photo',
        'live_photo_clip_url': clipUrl,
        'live_photo_clip_path': clipStoragePath,
        'live_photo_duration_ms': capture.clipDurationMs,
        'live_photo_pre_capture_ms': preCaptureMsFor(capture),
        'live_photo_photo_taken_at': DateTime.fromMillisecondsSinceEpoch(
          capture.photoTakenAtEpochMs,
          isUtc: false,
        ).toUtc().toIso8601String(),
        'live_photo_video_width': capture.videoWidth,
        'live_photo_video_height': capture.videoHeight,
        'live_photo_video_fps': capture.videoFps,
        'live_photo_muted': !hasAudibleAudio,
        if (normalizedPostDescription.isNotEmpty)
          'post_description': normalizedPostDescription,
      };

      final insertAttempts =
          <({Map<String, dynamic> payload, bool descriptionPersisted})>[];

      void addInsertAttempt(
        Map<String, dynamic> payload, {
        required bool descriptionWasIncluded,
      }) {
        insertAttempts.add((
          payload: Map<String, dynamic>.from(payload),
          descriptionPersisted:
              normalizedPostDescription.isEmpty || descriptionWasIncluded,
        ));
      }

      addInsertAttempt(
        basePayload,
        descriptionWasIncluded: basePayload.containsKey('post_description'),
      );
      if (normalizedPostDescription.isNotEmpty) {
        final withoutDescription = Map<String, dynamic>.from(basePayload)
          ..remove('post_description');
        addInsertAttempt(withoutDescription, descriptionWasIncluded: false);
      }

      Object? insertError;
      for (final attempt in insertAttempts) {
        try {
          final insertedRow = await client
              .from('photos')
              .insert(attempt.payload)
              .select('id, is_late')
              .single();
          insertedPhotoId = insertedRow['id']?.toString();
          effectiveIsLate = insertedRow['is_late'] == true;
          descriptionPersisted = attempt.descriptionPersisted;
          break;
        } catch (error) {
          insertError = error;
        }
      }

      if (insertedPhotoId == null) {
        throw insertError ?? StateError('Could not insert live photo row.');
      }

      // The post exists now: later steps must not fail the upload, and its
      // media must stay (the catch below only cleans up unposted uploads).
      try {
        if (descriptionPersisted && normalizedPostDescription.isNotEmpty) {
          await MentionService.createMentionNotifications(
            text: normalizedPostDescription,
            entityKind: MentionEntityKind.description,
            photoId: insertedPhotoId,
          );
        }
        await AnalyticsService.logPostCreated(
          isPublic: request.isPublic,
          isLate: effectiveIsLate,
        );
        await AnalyticsService.logChallengeCompleted(isLate: effectiveIsLate);
      } catch (error) {
        AppLogger.debug('Live photo follow-ups failed: $error');
      }

      // The server counts the streak on insert; late posts don't count.
      if (!effectiveIsLate) {
        resultingStreakCount = await readStreakAfterQuestPost(client, userId);
      }

      notifyPostDataChanged();

      if (request.deleteLocalFilesOnSuccess) {
        await _deleteLocalFiles(capture);
      }

      return LivePhotoPostCommitResult(
        photoId: insertedPhotoId,
        isLate: effectiveIsLate,
        descriptionPersisted: descriptionPersisted,
        streakCount: resultingStreakCount,
        stillUrl: stillUrl,
        liveClipUrl: clipUrl,
      );
    } catch (_) {
      // Only remove media of an upload that never became a post.
      if (insertedPhotoId != null) rethrow;
      if (clipUploaded) {
        try {
          await client.storage.from(_mediaBucket).remove([clipStoragePath]);
        } catch (_) {}
      }
      if (stillUploaded) {
        try {
          await client.storage.from(_mediaBucket).remove([
            stillStoragePath,
            thumbnailPathFor(stillStoragePath),
          ]);
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// How far into the clip the still was taken. Falls back to the clip
  /// length (still at the end) when the native timestamps don't fit.
  static int preCaptureMsFor(LivePhotoCaptureResult capture) {
    final offset = capture.photoTakenAtEpochMs - capture.clipStartEpochMs;
    if (capture.clipStartEpochMs <= 0 ||
        offset < 0 ||
        offset > capture.clipDurationMs) {
      return capture.clipDurationMs;
    }
    return offset;
  }

  Future<void> _deleteLocalFiles(LivePhotoCaptureResult capture) async {
    for (final path in <String>[capture.photoPath, capture.clipPath]) {
      if (path.trim().isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (error) {
        AppLogger.debug('Best-effort live photo cleanup failed for $path: $error');
      }
    }
  }

  DateTime challengeStartLocal(DateTime referenceLocal) {
    return challenge_time.challengeStartLocal(referenceLocal);
  }

  DateTime challengeEndLocal(DateTime referenceLocal) {
    return challenge_time.challengeEndLocal(referenceLocal);
  }

}
