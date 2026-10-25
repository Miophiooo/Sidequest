import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_logger.dart';
import '../../shared.dart';
import '../media/post_media.dart';

enum DuelOutcome { won, lost, draw, expired }

/// A finished duel of the signed-in user, for the result card.
class DuelResult {
  const DuelResult({
    required this.challengeId,
    required this.opponentId,
    required this.opponentName,
    required this.outcome,
    this.myPhotoUrl,
    this.opponentPhotoUrl,
    this.myLikes = 0,
    this.opponentLikes = 0,
  });

  final String challengeId;
  final String opponentId;
  final String opponentName;
  final DuelOutcome outcome;
  final String? myPhotoUrl;
  final String? opponentPhotoUrl;
  final int myLikes;
  final int opponentLikes;
}

/// Outcome from the server result: the winner, or a draw when both posted,
/// or expired when nobody did.
DuelOutcome duelOutcomeFor({
  required String me,
  required String? winnerId,
  required bool anyPhoto,
}) {
  final winner = winnerId?.trim() ?? '';
  if (winner.isNotEmpty) {
    return winner == me ? DuelOutcome.won : DuelOutcome.lost;
  }
  return anyPhoto ? DuelOutcome.draw : DuelOutcome.expired;
}

class DuelResults {
  DuelResults._();

  static const Duration _shownFor = Duration(hours: 48);

  static String _seenKey(String userId) => 'duel_results_seen_v1_$userId';

  /// Duels finished in the last 2 days that the user hasn't closed yet.
  static Future<List<DuelResult>> loadUnseen() async {
    final client = Supabase.instance.client;
    final me = client.auth.currentUser?.id;
    if (me == null) return const [];

    try {
      final seen = await _loadSeen(me);
      final since = DateTime.now()
          .toUtc()
          .subtract(_shownFor)
          .toIso8601String();
      final rows = await client
          .from('challenges')
          .select(
            'id, challenger_id, challenged_id, winner_id, completed_at, '
            'expires_at, challenger_expires_at, challenged_expires_at',
          )
          .or('challenger_id.eq.$me,challenged_id.eq.$me')
          .gte('completed_at', since)
          .order('completed_at', ascending: false)
          .limit(10);

      final duels = List<Map<String, dynamic>>.from(rows as List)
          .where((d) => !seen.contains((d['id'] ?? '').toString()))
          // Accepted duels only; declined or expired invites have no timer.
          .where(
            (d) =>
                d['expires_at'] != null ||
                d['challenger_expires_at'] != null ||
                d['challenged_expires_at'] != null,
          )
          .toList(growable: false);
      if (duels.isEmpty) return const [];

      final ids = duels.map((d) => d['id'].toString()).toList();
      final opponentIds = {
        for (final d in duels)
          (d['challenger_id'] == me ? d['challenged_id'] : d['challenger_id'])
              .toString(),
      }.toList();

      final photos = List<Map<String, dynamic>>.from(
        await client
                .from('photos')
                .select('id, user_id, url, thumb_url, challenge_id')
                .inFilter('challenge_id', ids)
            as List,
      );
      final photoIds = photos.map((p) => p['id'].toString()).toList();
      final List<dynamic> likes = photoIds.isEmpty
          ? const <dynamic>[]
          : await client
                .from('likes')
                .select('photo_id, server_created_at')
                .inFilter('photo_id', photoIds);
      // Same count as the server's decision: likes until the duel closed.
      final closedAt = {
        for (final d in duels)
          d['id'].toString(): parseUtcTimestamp(d['completed_at']),
      };
      final duelOfPhoto = {
        for (final p in photos)
          p['id'].toString(): p['challenge_id'].toString(),
      };
      final likeCount = <String, int>{};
      for (final like in likes) {
        final id = (like['photo_id'] ?? '').toString();
        final likedAt = parseUtcTimestamp(like['server_created_at']);
        final cutoff = closedAt[duelOfPhoto[id]];
        if (likedAt != null && cutoff != null && likedAt.isAfter(cutoff)) {
          continue;
        }
        likeCount[id] = (likeCount[id] ?? 0) + 1;
      }

      final profiles = List<Map<String, dynamic>>.from(
        await client
                .from('users_profile')
                .select('id, username')
                .inFilter('id', opponentIds)
            as List,
      );
      final nameById = {
        for (final p in profiles)
          p['id'].toString(): (p['username'] ?? '').toString(),
      };

      return [
        for (final d in duels) _toResult(d, me, photos, likeCount, nameById),
      ];
    } catch (e) {
      AppLogger.debug('Loading duel results failed: $e');
      return const [];
    }
  }

  static DuelResult _toResult(
    Map<String, dynamic> duel,
    String me,
    List<Map<String, dynamic>> photos,
    Map<String, int> likeCount,
    Map<String, String> nameById,
  ) {
    final id = duel['id'].toString();
    final opponentId =
        (duel['challenger_id'] == me
                ? duel['challenged_id']
                : duel['challenger_id'])
            .toString();
    Map<String, dynamic>? photoOf(String userId) {
      for (final p in photos) {
        if (p['challenge_id'].toString() == id &&
            p['user_id'].toString() == userId) {
          return p;
        }
      }
      return null;
    }

    final mine = photoOf(me);
    final theirs = photoOf(opponentId);
    return DuelResult(
      challengeId: id,
      opponentId: opponentId,
      opponentName: nameById[opponentId] ?? '',
      outcome: duelOutcomeFor(
        me: me,
        winnerId: duel['winner_id']?.toString(),
        anyPhoto: mine != null || theirs != null,
      ),
      myPhotoUrl: mine == null ? null : listImageUrl(mine),
      opponentPhotoUrl: theirs == null ? null : listImageUrl(theirs),
      myLikes: mine == null ? 0 : likeCount[mine['id'].toString()] ?? 0,
      opponentLikes: theirs == null
          ? 0
          : likeCount[theirs['id'].toString()] ?? 0,
    );
  }

  static Future<Set<String>> _loadSeen(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_seenKey(userId));
      if (raw == null) return <String>{};
      return (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  /// Hides the card for this duel on this device.
  static Future<void> markSeen(String challengeId) async {
    final me = Supabase.instance.client.auth.currentUser?.id;
    if (me == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = await _loadSeen(me)
        ..add(challengeId);
      // Keep the list short; old ids no longer match the 48 h window.
      final kept = seen.toList().reversed.take(50).toList();
      await prefs.setString(_seenKey(me), jsonEncode(kept));
    } catch (_) {}
  }
}

/// "Duell gewonnen 🏆" card with both photos and their likes.
class DuelResultCard extends StatelessWidget {
  const DuelResultCard({
    super.key,
    required this.result,
    required this.onClose,
    required this.onRematch,
  });

  final DuelResult result;
  final VoidCallback onClose;
  final VoidCallback onRematch;

  @override
  Widget build(BuildContext context) {
    final name = result.opponentName.isEmpty
        ? t('deinen Freund', 'your friend')
        : '@${result.opponentName}';
    final (emoji, title, accent) = switch (result.outcome) {
      DuelOutcome.won => ('🏆', t('Duell gewonnen!', 'Duel won!'), appGreen),
      DuelOutcome.lost => (
        '⚔️',
        t('Duell verloren', 'Duel lost'),
        const Color(0xFFFF8A65),
      ),
      DuelOutcome.draw => (
        '🤝',
        t('Unentschieden', "It's a draw"),
        const Color(0xFFFFC14D),
      ),
      DuelOutcome.expired => (
        '⌛',
        t('Duell abgelaufen', 'Duel expired'),
        const Color(0xFF9E9E9E),
      ),
    };
    final subtitle = switch (result.outcome) {
      DuelOutcome.won => t('gegen $name', 'against $name'),
      DuelOutcome.lost => t('$name war diesmal besser', '$name won this time'),
      DuelOutcome.draw => t(
        'gleich viele Likes wie $name',
        'same likes as $name',
      ),
      DuelOutcome.expired => t(
        'niemand hat ein Foto gepostet',
        'nobody posted a photo',
      ),
    };

    return Container(
      width: 290,
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.7), width: 1.3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: accent,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFFBDBDBD),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: t('Schließen', 'Close'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: Colors.white54,
                ),
                onPressed: onClose,
              ),
            ],
          ),
          if (result.outcome != DuelOutcome.expired) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: _PhotoWithLikes(
                      label: t('Du', 'You'),
                      url: result.myPhotoUrl,
                      likes: result.myLikes,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _PhotoWithLikes(
                      label: result.opponentName.isEmpty
                          ? t('Gegner', 'Opponent')
                          : result.opponentName,
                      url: result.opponentPhotoUrl,
                      likes: result.opponentLikes,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox(
              width: double.infinity,
              height: 36,
              child: OutlinedButton.icon(
                onPressed: onRematch,
                icon: const Icon(
                  Icons.flash_on_rounded,
                  size: 16,
                  color: Colors.amber,
                ),
                label: Text(
                  t('Revanche', 'Rematch'),
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Colors.amber,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.amber.withValues(alpha: 0.6)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoWithLikes extends StatelessWidget {
  const _PhotoWithLikes({
    required this.label,
    required this.url,
    required this.likes,
  });

  final String label;
  final String? url;
  final int likes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 70,
            width: double.infinity,
            child: url == null
                ? Container(
                    color: const Color(0xFF2A2A2A),
                    alignment: Alignment.center,
                    child: Text(
                      t('kein Foto', 'no photo'),
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: Colors.white38,
                      ),
                    ),
                  )
                : sideQuestNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.cover,
                    cacheWidth: sideQuestCacheWidth(context, 130),
                    errorWidget: Container(color: const Color(0xFF2A2A2A)),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$label · ❤️ $likes',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.inter(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: Colors.white70,
          ),
        ),
      ],
    );
  }
}
