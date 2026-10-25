import 'package:supabase_flutter/supabase_flutter.dart';

class BlockRelationStatus {
  final bool blockedByMe;
  final bool blockedMe;

  const BlockRelationStatus({
    required this.blockedByMe,
    required this.blockedMe,
  });

  bool get isBlocked => blockedByMe || blockedMe;
}

class BlockedUserItem {
  final String id;
  final String username;
  final String? profilePicture;

  const BlockedUserItem({
    required this.id,
    required this.username,
    required this.profilePicture,
  });
}

class BlockService {
  static SupabaseClient get _client => Supabase.instance.client;

  static Future<List<Map<String, dynamic>>> _loadRowsForUser(String userId) async {
    if (userId.isEmpty) return const [];

    try {
      final rows = await _client
          .from('user_blocks')
          .select('blocker_id, blocked_id')
          .or('blocker_id.eq.$userId,blocked_id.eq.$userId');
      return (rows as List)
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<Set<String>> loadBlockedRelationshipIdsForUser(String userId) async {
    final rows = await _loadRowsForUser(userId);
    final ids = <String>{};

    for (final row in rows) {
      final blockerId = (row['blocker_id'] ?? '').toString().trim();
      final blockedId = (row['blocked_id'] ?? '').toString().trim();
      if (blockerId == userId && blockedId.isNotEmpty) {
        ids.add(blockedId);
      } else if (blockedId == userId && blockerId.isNotEmpty) {
        ids.add(blockerId);
      }
    }

    return ids;
  }

  static Future<BlockRelationStatus> loadRelationStatus(String otherUserId) async {
    final currentUserId = _client.auth.currentUser?.id ?? '';
    if (currentUserId.isEmpty || otherUserId.isEmpty || otherUserId == currentUserId) {
      return const BlockRelationStatus(blockedByMe: false, blockedMe: false);
    }

    try {
      final rows = await _client
          .from('user_blocks')
          .select('blocker_id, blocked_id')
          .or(
            'and(blocker_id.eq.$currentUserId,blocked_id.eq.$otherUserId),and(blocker_id.eq.$otherUserId,blocked_id.eq.$currentUserId)',
          );

      var blockedByMe = false;
      var blockedMe = false;

      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final blockerId = (row['blocker_id'] ?? '').toString().trim();
        final blockedId = (row['blocked_id'] ?? '').toString().trim();
        if (blockerId == currentUserId && blockedId == otherUserId) {
          blockedByMe = true;
        }
        if (blockerId == otherUserId && blockedId == currentUserId) {
          blockedMe = true;
        }
      }

      return BlockRelationStatus(blockedByMe: blockedByMe, blockedMe: blockedMe);
    } catch (_) {
      return const BlockRelationStatus(blockedByMe: false, blockedMe: false);
    }
  }

  static Future<void> blockUser(String otherUserId) async {
    final currentUserId = _client.auth.currentUser?.id ?? '';
    if (currentUserId.isEmpty || otherUserId.isEmpty || otherUserId == currentUserId) {
      return;
    }

    await _client.from('user_blocks').upsert({
      'blocker_id': currentUserId,
      'blocked_id': otherUserId,
    });

    try {
      await _client
          .from('friends')
          .delete()
          .or(
            'and(user_id.eq.$currentUserId,friend_id.eq.$otherUserId),and(user_id.eq.$otherUserId,friend_id.eq.$currentUserId)',
          );
    } catch (_) {
      // Best effort: the block itself is more important than friendship cleanup.
    }
  }

  static Future<void> unblockUser(String otherUserId) async {
    final currentUserId = _client.auth.currentUser?.id ?? '';
    if (currentUserId.isEmpty || otherUserId.isEmpty || otherUserId == currentUserId) {
      return;
    }

    await _client
        .from('user_blocks')
        .delete()
        .eq('blocker_id', currentUserId)
        .eq('blocked_id', otherUserId);
  }

  static Future<List<BlockedUserItem>> loadBlockedUsers() async {
    final currentUserId = _client.auth.currentUser?.id ?? '';
    if (currentUserId.isEmpty) return const [];

    try {
      final rows = await _client
          .from('user_blocks')
          .select('blocked_id')
          .eq('blocker_id', currentUserId)
          .order('created_at', ascending: false);

      final blockedIds = (rows as List)
          .whereType<Map>()
          .map((row) => (row['blocked_id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toList(growable: false);

      if (blockedIds.isEmpty) return const [];

      final profiles = await _client
          .from('users_profile')
          .select('id, username, profile_picture')
          .inFilter('id', blockedIds);

      final byId = <String, BlockedUserItem>{};
      for (final raw in profiles as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = (row['id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        final picture = (row['profile_picture'] ?? '').toString().trim();
        byId[id] = BlockedUserItem(
          id: id,
          username: (row['username'] ?? 'Unknown').toString(),
          profilePicture: picture.isEmpty ? null : picture,
        );
      }

      return blockedIds
          .map(
            (id) => byId[id] ??
                BlockedUserItem(id: id, username: 'Unknown', profilePicture: null),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}
