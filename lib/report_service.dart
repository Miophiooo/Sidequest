import 'package:supabase_flutter/supabase_flutter.dart';

enum ReportTargetType { photo, comment }

enum ReportSubmissionResult { created, alreadyReported }

class ReportService {
  static Future<ReportSubmissionResult> submit({
    required SupabaseClient client,
    required ReportTargetType targetType,
    String? photoId,
    String? commentId,
    String? reportedUserId,
  }) async {
    final reporterId = client.auth.currentUser?.id;
    if (reporterId == null || reporterId.isEmpty) {
      throw StateError('No authenticated user available for reporting');
    }

    final normalizedPhotoId = (photoId ?? '').trim();
    final normalizedCommentId = (commentId ?? '').trim();
    final normalizedReportedUserId = (reportedUserId ?? '').trim();

    if (targetType == ReportTargetType.photo && normalizedPhotoId.isEmpty) {
      throw ArgumentError('photoId is required for photo reports');
    }
    if (targetType == ReportTargetType.comment && normalizedCommentId.isEmpty) {
      throw ArgumentError('commentId is required for comment reports');
    }

    try {
      await client.from('content_reports').insert({
        'reporter_id': reporterId,
        'target_type': targetType.name,
        'photo_id': normalizedPhotoId.isEmpty ? null : normalizedPhotoId,
        'comment_id': normalizedCommentId.isEmpty ? null : normalizedCommentId,
        'reported_user_id': normalizedReportedUserId.isEmpty
            ? null
            : normalizedReportedUserId,
        'created_at': DateTime.now().toIso8601String(),
      });
      return ReportSubmissionResult.created;
    } on PostgrestException catch (e) {
      final code = (e.code ?? '').trim();
      final message = e.message.toLowerCase();
      final isDuplicate =
          code == '23505' ||
          message.contains('duplicate') ||
          message.contains('unique');
      if (isDuplicate) {
        return ReportSubmissionResult.alreadyReported;
      }
      rethrow;
    }
  }
}
