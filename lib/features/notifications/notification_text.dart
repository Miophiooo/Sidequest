import '../../shared.dart';

/// Emoji shown in the notification center for each entry type.
String notificationEmoji(String type) => switch (type) {
  'like' => '❤️',
  'comment' => '💬',
  'friend_request' => '👋',
  'friend_accepted' => '🤝',
  'duel_invite' || 'duel_accepted' => '⚔️',
  'duel_result' => '🏆',
  'crowd_favorite' => '👑',
  'mention' => '@',
  'joker_auto_used' => '🃏',
  _ => '🔔',
};

/// Requests and duels have no photo; tapping them opens the friends tab.
bool notificationOpensFriendsTab(String type) => const {
  'friend_request',
  'friend_accepted',
  'duel_invite',
  'duel_accepted',
  'duel_result',
}.contains(type);

/// Text of an entry in the current app language. [actorName] is the
/// username of whoever caused it, [me] the signed-in user (for duel results).
/// Types the app doesn't know (auto joker, old mentions) use the stored
/// message.
String notificationText(
  Map<String, dynamic> row, {
  String? actorName,
  String? me,
}) {
  final type = (row['type'] ?? '').toString();
  final rawData = row['data'];
  final data = rawData is Map
      ? Map<String, dynamic>.from(rawData)
      : const <String, dynamic>{};
  final name = (actorName ?? '').trim();
  final who = name.isEmpty ? t('Jemand', 'Someone') : '@$name';

  switch (type) {
    case 'like':
      return t('$who gefällt dein Foto', '$who liked your photo');
    case 'comment':
      final msg = (data['message'] ?? '').toString().trim();
      return msg.isEmpty
          ? t('$who hat dein Foto kommentiert', '$who commented on your photo')
          : t('$who hat kommentiert: „$msg“', '$who commented: "$msg"');
    case 'friend_request':
      return t(
        '$who möchte mit dir befreundet sein',
        '$who sent you a friend request',
      );
    case 'friend_accepted':
      return t('$who ist jetzt mit dir befreundet', '$who is now your friend');
    case 'duel_invite':
      return t(
        '$who fordert dich zum Duell heraus',
        '$who challenged you to a duel',
      );
    case 'duel_accepted':
      return t(
        '$who hat dein Duell angenommen – 30 Minuten für dein Foto',
        '$who accepted your duel – 30 minutes for your photo',
      );
    case 'duel_result':
      final winner = (data['winner_id'] ?? '').toString();
      if (winner.isNotEmpty && winner == me) {
        return t(
          'Du hast das Duell gegen $who gewonnen',
          'You won the duel against $who',
        );
      }
      if (winner.isNotEmpty) {
        return t('$who hat das Duell gewonnen', '$who won the duel');
      }
      return data['had_photos'] == true
          ? t(
              'Dein Duell gegen $who endet unentschieden',
              'Your duel against $who ended in a draw',
            )
          : t(
              'Im Duell gegen $who hat niemand gepostet',
              'Nobody posted in the duel against $who',
            );
    case 'mention' when data['entity'] != null:
      final preview = (data['preview'] ?? '').toString().trim();
      final inDescription = data['entity'] == 'description';
      final base = inDescription
          ? t(
              '$who hat dich in einer Beschreibung erwähnt',
              '$who mentioned you in a description',
            )
          : t(
              '$who hat dich in einem Kommentar erwähnt',
              '$who mentioned you in a comment',
            );
      return preview.isEmpty ? base : '$base: „$preview“';
    case 'crowd_favorite':
      final bonus = (data['joker_bonus'] as num?)?.toInt() ?? 3;
      return t(
        'Du bist Crowd Favorite! Dein Foto hatte die meisten Likes – +$bonus Joker',
        'You are Crowd Favorite! Your photo got the most likes – +$bonus jokers',
      );
    default:
      return (row['message'] ?? '').toString();
  }
}

const List<String> _monthsEn = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "gerade eben", "vor 5 Min.", "vor 3 Std.", "gestern", "vor 4 Tagen",
/// then the date.
String relativeTimeLabel(DateTime timestamp, {DateTime? now}) {
  final current = (now ?? DateTime.now()).toLocal();
  final local = timestamp.toLocal();
  final diff = current.difference(local);
  if (diff.inMinutes < 1) return t('gerade eben', 'just now');
  if (diff.inMinutes < 60) {
    return t('vor ${diff.inMinutes} Min.', '${diff.inMinutes} min ago');
  }
  if (diff.inHours < 24) {
    return t('vor ${diff.inHours} Std.', '${diff.inHours} h ago');
  }
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(local.year, local.month, local.day);
  // Rounded, so a daylight-saving switch doesn't shift the day.
  final days = (today.difference(day).inHours / 24).round();
  if (days <= 1) return t('gestern', 'yesterday');
  if (days < 7) return t('vor $days Tagen', '$days days ago');
  final dd = local.day.toString().padLeft(2, '0');
  final mm = local.month.toString().padLeft(2, '0');
  return t('$dd.$mm.', '${_monthsEn[local.month - 1]} ${local.day}');
}
