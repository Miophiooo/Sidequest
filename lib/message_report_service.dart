import 'package:supabase_flutter/supabase_flutter.dart';

enum MessageReportSubmissionResult { created, alreadyReported }

class MessageReportService {
  static Future<MessageReportSubmissionResult> submitConversationReport({
    required SupabaseClient client,
    required String messageId,
    required String otherUserId,
  }) async {
    final reporterId = client.auth.currentUser?.id;
    if (reporterId == null || reporterId.isEmpty) {
      throw StateError('No authenticated user available for message reports');
    }

    final normalizedMessageId = messageId.trim();
    final normalizedOtherUserId = otherUserId.trim();
    if (normalizedMessageId.isEmpty) {
      throw ArgumentError('messageId is required for message reports');
    }
    if (normalizedOtherUserId.isEmpty) {
      throw ArgumentError('otherUserId is required for message reports');
    }

    final recentRows = await client
        .from('messages')
        .select('id, sender_id, receiver_id, message, created_at')
        .or(
          'and(sender_id.eq.$reporterId,receiver_id.eq.$normalizedOtherUserId),and(sender_id.eq.$normalizedOtherUserId,receiver_id.eq.$reporterId)',
        )
        .order('created_at', ascending: false)
        .limit(5);

    final recentMessages = List<Map<String, dynamic>>.from(
      (recentRows as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList()
          .reversed,
    );

    try {
      await client.from('message_reports').insert({
        'reporter_id': reporterId,
        'reported_user_id': normalizedOtherUserId,
        'conversation_partner_id': normalizedOtherUserId,
        'message_id': normalizedMessageId,
        'recent_messages': recentMessages,
        'created_at': DateTime.now().toIso8601String(),
      });
      return MessageReportSubmissionResult.created;
    } on PostgrestException catch (e) {
      final code = (e.code ?? '').trim();
      final message = e.message.toLowerCase();
      final isDuplicate =
          code == '23505' ||
          message.contains('duplicate') ||
          message.contains('unique');
      if (isDuplicate) {
        return MessageReportSubmissionResult.alreadyReported;
      }
      rethrow;
    }
  }
}
