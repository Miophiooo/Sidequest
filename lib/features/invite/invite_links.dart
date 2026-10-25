import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_environment.dart';
import '../../core/app_logger.dart';
import '../../friend_discovery.dart';
import '../../shared.dart';

/// Friend invite links with the inviter's username.
///
/// `https://<project>.supabase.co/functions/v1/invite?u=<username>` (edge
/// function `invite`) redirects to `io.supabase.sidequest://invite?u=...`.
/// Opening it sends a friend request to that user as soon as the app is
/// signed in – also after a fresh install + signup, because the username is
/// kept until then.
class InviteLinks {
  InviteLinks._();

  static const String _prefsKey = 'pending_invite_username_v1';
  static final RegExp _usernamePattern = RegExp(
    r'^[A-Za-z0-9_ÄÖÜßäöüẞ]{1,32}$',
  );

  /// Username from an opened invite link that still needs a friend request.
  static final ValueNotifier<String?> pendingUsername = ValueNotifier(null);

  static StreamSubscription<Uri>? _subscription;
  static bool _processing = false;

  /// Shareable link for [username].
  static String linkFor(String username) => Uri.parse(
    AppEnvironment.inviteLinkBase,
  ).replace(queryParameters: {'u': username}).toString();

  /// The invited username if [uri] is an invite link, otherwise null.
  static String? usernameFrom(Uri uri) {
    final isAppLink =
        uri.scheme == 'io.supabase.sidequest' && uri.host == 'invite';
    final base = Uri.tryParse(AppEnvironment.inviteLinkBase);
    final isWebLink =
        base != null &&
        uri.scheme == base.scheme &&
        uri.host == base.host &&
        uri.path == base.path;
    if (!isAppLink && !isWebLink) return null;

    final username = (uri.queryParameters['u'] ?? '').trim();
    return _usernamePattern.hasMatch(username) ? username : null;
  }

  /// Starts listening for invite links (cold start and while running).
  static Future<void> start() async {
    if (kIsWeb || _subscription != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved != null && saved.isNotEmpty) pendingUsername.value = saved;
    } catch (_) {}

    final appLinks = AppLinks();
    _subscription = appLinks.uriLinkStream.listen(
      _handle,
      onError: (Object e) => AppLogger.warn('Invite link stream failed: $e'),
    );
    try {
      final initial = await appLinks.getInitialLink();
      if (initial != null) await _handle(initial);
    } catch (e) {
      AppLogger.warn('Reading initial invite link failed: $e');
    }
  }

  static Future<void> _handle(Uri uri) async {
    final username = usernameFrom(uri);
    if (username == null) return;
    pendingUsername.value = username;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, username);
    } catch (_) {}
  }

  static Future<void> _clearPending() async {
    pendingUsername.value = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }

  /// Sends the friend request for a pending invite. Call once the signed-in
  /// main screen is shown; [context] is used for the result snackbar.
  static Future<void> processPending(BuildContext context) async {
    final username = pendingUsername.value;
    final client = Supabase.instance.client;
    if (username == null || _processing || client.auth.currentUser == null) {
      return;
    }
    _processing = true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    void show(String de, String en) =>
        messenger?.showSnackBar(SnackBar(content: Text(t(de, en))));

    try {
      // Escape LIKE wildcards: "_" is allowed in usernames.
      final pattern = username
          .replaceAll(r'\', r'\\')
          .replaceAll('%', r'\%')
          .replaceAll('_', r'\_');
      final row = await client
          .from('users_profile')
          .select('id, username')
          .ilike('username', pattern)
          .limit(1)
          .maybeSingle();
      await _clearPending();

      if (row == null) {
        show('@$username wurde nicht gefunden.', '@$username was not found.');
        return;
      }

      final name = (row['username'] ?? username).toString();
      final result = await FriendDiscoveryService.sendFriendRequest(
        (row['id'] ?? '').toString(),
      );
      switch (result) {
        case FriendRequestResult.sent:
          show(
            'Freundschaftsanfrage an @$name gesendet 🎉',
            'Friend request sent to @$name 🎉',
          );
          mainTabNavigationRequestNotifier.value = 1;
        case FriendRequestResult.alreadyExists:
          show(
            'Mit @$name bist du schon befreundet oder es gibt schon eine Anfrage.',
            'You are already friends with @$name or a request is pending.',
          );
          mainTabNavigationRequestNotifier.value = 1;
        case FriendRequestResult.self:
          show(
            'Das ist dein eigener Link – schick ihn deinen Freunden.',
            'That is your own link – send it to your friends.',
          );
        case FriendRequestResult.blocked:
          show(
            'Mit @$name ist keine Freundschaft möglich.',
            'You can\'t add @$name as a friend.',
          );
        case FriendRequestResult.failed:
          show(
            'Die Anfrage an @$name hat nicht geklappt. Bitte versuch es erneut.',
            'The request to @$name failed. Please try again.',
          );
      }
    } catch (e) {
      AppLogger.warn('Processing invite link failed: $e');
    } finally {
      _processing = false;
    }
  }
}
