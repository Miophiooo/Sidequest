import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../analytics_service.dart';
import '../../core/app_environment.dart';
import '../../core/app_logger.dart';
import '../../shared.dart';
import 'invite_links.dart';

/// Personal invite with the inviter's link (see [InviteLinks]): whoever taps
/// it sends the inviter a friend request. Falls back to the website when the
/// username is unknown.
String buildSideQuestInviteMessage({String? username}) {
  final handle = (username ?? '').trim();
  if (handle.isEmpty) {
    return t(
      'Ich nutze SideQuest für tägliche Foto-Quests, Streaks und kleine Duelle. Probier es aus: ${AppEnvironment.websiteUrl}',
      'I use SideQuest for daily photo quests, streaks, and quick duels. Give it a try: ${AppEnvironment.websiteUrl}',
    );
  }
  final link = InviteLinks.linkFor(handle);
  return t(
    'Lass uns auf SideQuest befreundet sein! Ich bin @$handle – tipp auf den Link, um mich hinzuzufügen:\n$link',
    'Let\'s be friends on SideQuest! I\'m @$handle – tap the link to add me:\n$link',
  );
}

/// Opens the system share sheet with the caller's invite link. [context]
/// anchors the share popover (required on iPad) and shows a fallback: if
/// sharing fails, the message is copied to the clipboard instead of nothing
/// happening.
Future<void> shareSideQuestInvite({
  required String surface,
  BuildContext? context,
}) async {
  // Read the anchor before any await, while the context is surely mounted.
  Rect? origin;
  final box = context?.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    origin = box.localToGlobal(Offset.zero) & box.size;
  }
  final messenger = context == null ? null : ScaffoldMessenger.maybeOf(context);

  String? username;
  try {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId != null && userId.isNotEmpty) {
      final row = await client
          .from('users_profile')
          .select('username')
          .eq('id', userId)
          .maybeSingle();
      final value = (row?['username'] ?? '').toString().trim();
      if (value.isNotEmpty) username = value;
    }
  } catch (e) {
    AppLogger.warn('Loading username for invite failed: $e');
  }

  final message = buildSideQuestInviteMessage(username: username);
  await AnalyticsService.logInviteSent(type: 'app_invite_$surface');
  try {
    await Share.share(
      message,
      subject: t('SideQuest Einladung', 'SideQuest invite'),
      sharePositionOrigin: origin,
    );
  } catch (e) {
    AppLogger.warn('Sharing invite failed: $e');
    await Clipboard.setData(ClipboardData(text: message));
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          t(
            'Link kopiert – füg ihn in einen Chat ein.',
            'Link copied – paste it into a chat.',
          ),
        ),
      ),
    );
  }
}
