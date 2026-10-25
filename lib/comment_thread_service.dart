import 'package:supabase_flutter/supabase_flutter.dart';

import 'block_service.dart';

class CommentThreadService {
  static Future<List<Map<String, dynamic>>> loadComments({
    required SupabaseClient client,
    required List<String> photoIds,
  }) async {
    final normalizedPhotoIds = photoIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalizedPhotoIds.isEmpty) return const [];

    final currentUserId = client.auth.currentUser?.id ?? '';
    final blockedUserIds = currentUserId.isEmpty
        ? <String>{}
        : await BlockService.loadBlockedRelationshipIdsForUser(currentUserId);

    final dynamic rawComments = normalizedPhotoIds.length == 1
        ? await client
              .from('comments')
              .select('id, photo_id, user_id, message, created_at')
              .eq('photo_id', normalizedPhotoIds.first)
              .order('created_at', ascending: true)
        : await client
              .from('comments')
              .select('id, photo_id, user_id, message, created_at')
              .inFilter('photo_id', normalizedPhotoIds)
              .order('created_at', ascending: true);

    final comments = List<Map<String, dynamic>>.from(
      (rawComments as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .where((comment) {
            final userId = (comment['user_id'] ?? '').toString().trim();
            return userId.isEmpty || !blockedUserIds.contains(userId);
          })
          .toList(growable: false),
    );
    if (comments.isEmpty) return const [];

    final commentIds = comments
        .map((c) => (c['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final userIds = comments
        .map((c) => (c['user_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);

    List<dynamic> rawCommentLikes = const [];
    if (commentIds.isNotEmpty) {
      try {
        rawCommentLikes = await client
            .from('comment_likes')
            .select('comment_id, user_id')
            .inFilter('comment_id', commentIds);
      } catch (_) {
        rawCommentLikes = const [];
      }
    }

    final profiles = userIds.isEmpty
        ? const []
        : await client
              .from('users_profile')
              .select('id, username, profile_picture')
              .inFilter('id', userIds);

    final profileByUserId = <String, Map<String, dynamic>>{
      for (final row in profiles)
        (row['id'] ?? '').toString(): Map<String, dynamic>.from(row as Map),
    };

    final likeCountByCommentId = <String, int>{};
    final likedCommentIds = <String>{};
    for (final row in rawCommentLikes) {
      final map = Map<String, dynamic>.from(row as Map);
      final commentId = (map['comment_id'] ?? '').toString();
      final userId = (map['user_id'] ?? '').toString();
      if (commentId.isEmpty) continue;
      likeCountByCommentId[commentId] =
          (likeCountByCommentId[commentId] ?? 0) + 1;
      if (currentUserId.isNotEmpty && userId == currentUserId) {
        likedCommentIds.add(commentId);
      }
    }

    return comments
        .map((comment) {
          final userId = (comment['user_id'] ?? '').toString();
          final commentId = (comment['id'] ?? '').toString();
          final profile = profileByUserId[userId] ?? const <String, dynamic>{};
          return {
            ...comment,
            'username': profile['username'] ?? 'Unknown',
            'avatar': profile['profile_picture'],
            'users_profile': profile,
            'likes_count': likeCountByCommentId[commentId] ?? 0,
            'is_liked': likedCommentIds.contains(commentId),
            'is_own': currentUserId.isNotEmpty && userId == currentUserId,
          };
        })
        .toList(growable: false);
  }
}
