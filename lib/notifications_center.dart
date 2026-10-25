import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/app_logger.dart';
import 'features/notifications/notification_text.dart';
import 'shared.dart';

class NotificationInboxButton extends StatefulWidget {
  final Color iconColor;

  const NotificationInboxButton({super.key, required this.iconColor});

  @override
  State<NotificationInboxButton> createState() =>
      _NotificationInboxButtonState();
}

class _NotificationInboxButtonState extends State<NotificationInboxButton> {
  RealtimeChannel? _channel;
  int _unreadCount = 0;

  @override
  void initState() {
    super.initState();
    _loadUnreadCount();
    _subscribe();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<void> _loadUnreadCount() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    try {
      final unread = await client
          .from('notifications')
          .select('id')
          .eq('user_id', userId)
          .eq('read', false);

      if (!mounted) return;
      setState(() => _unreadCount = unread.length);
    } catch (e) {
      AppLogger.debug('Loading unread notification count failed: $e');
    }
  }

  void _subscribe() {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    _channel?.unsubscribe();
    _channel = client
        .channel('notifications_badge_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) {
            _loadUnreadCount();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) {
            _loadUnreadCount();
          },
        )
        .subscribe();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const NotificationsCenterScreen(),
              ),
            );
            _loadUnreadCount();
          },
          icon: Icon(Icons.notifications_none_rounded, color: widget.iconColor),
        ),
        if (_unreadCount > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              decoration: BoxDecoration(
                color: Colors.redAccent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Center(
                child: Text(
                  _unreadCount > 99 ? '99+' : _unreadCount.toString(),
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class NotificationsCenterScreen extends StatefulWidget {
  const NotificationsCenterScreen({super.key});

  @override
  State<NotificationsCenterScreen> createState() =>
      _NotificationsCenterScreenState();
}

class _NotificationsCenterScreenState extends State<NotificationsCenterScreen> {
  final List<Map<String, dynamic>> _notifications = [];
  final Map<String, String> _actorNames = {};
  bool _loading = true;
  bool _markingRead = false;
  RealtimeChannel? _channel;
  Timer? _reloadDebounce;

  @override
  void initState() {
    super.initState();
    _loadNotifications(markAsRead: true);
    _subscribe();
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _channel?.unsubscribe();
    super.dispose();
  }

  void _scheduleNotificationsReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(
      const Duration(milliseconds: 180),
      () => _loadNotifications(),
    );
  }

  Future<void> _loadNotifications({bool markAsRead = false}) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    try {
      final List<dynamic> rows = await client
          .from('notifications')
          .select(
            'id, type, message, read, created_at, photo_id, comment_id, '
            'challenge_id, actor_id, data',
          )
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(100);

      // Usernames of everyone in the list, in one request.
      final missingActorIds = {
        for (final row in rows) (row['actor_id'] ?? '').toString(),
      }..removeWhere((id) => id.isEmpty || _actorNames.containsKey(id));
      if (missingActorIds.isNotEmpty) {
        try {
          final profiles = await client
              .from('users_profile')
              .select('id, username')
              .inFilter('id', missingActorIds.toList());
          for (final p in profiles) {
            _actorNames[(p['id'] ?? '').toString()] = (p['username'] ?? '')
                .toString();
          }
        } catch (e) {
          AppLogger.debug('Loading notification actors failed: $e');
        }
      }

      if (!mounted) return;
      setState(() {
        _notifications
          ..clear()
          ..addAll(
            List<Map<String, dynamic>>.from(
              rows.map((row) => Map<String, dynamic>.from(row)),
            ),
          );
        _loading = false;
      });

      if (markAsRead) {
        await _markAllAsRead();
      }
    } catch (e) {
      AppLogger.debug('Error loading notifications: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _openNotification(Map<String, dynamic> item) async {
    final photoId = (item['photo_id'] ?? '').toString().trim();
    final commentId = (item['comment_id'] ?? '').toString().trim();
    if (photoId.isEmpty) {
      if (notificationOpensFriendsTab((item['type'] ?? '').toString())) {
        requestMainTabNavigation(1);
        Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
      }
      return;
    }

    final client = Supabase.instance.client;
    try {
      final row = await client
          .from('photos')
          .select('id, is_public, is_challenge_photo, is_late')
          .eq('id', photoId)
          .maybeSingle();

      if (row == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Diesen Post kannst du nicht ansehen.',
                'You cannot view this post.',
              ),
            ),
          ),
        );
        return;
      }

      final isPublic = row['is_public'] == true;
      final isChallenge = row['is_challenge_photo'] == true;
      final isLate = row['is_late'] == true;
      final targetTabIndex = isPublic ? 2 : 0;

      requestMainTabNavigation(targetTabIndex);
      requestPostFocus(
        PostFocusRequest(
          tabIndex: targetTabIndex,
          photoId: photoId,
          commentId: commentId.isEmpty ? null : commentId,
          todayFeedFilter: targetTabIndex == 0
              ? (isChallenge && !isLate ? 'pvp' : 'daily')
              : null,
        ),
      );

      if (!mounted) return;
      Navigator.of(
        context,
        rootNavigator: true,
      ).popUntil((route) => route.isFirst);
    } catch (e) {
      AppLogger.debug('Error opening notification target: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Diesen Post kannst du gerade nicht öffnen.',
              'Could not open this post right now.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _markAllAsRead() async {
    if (_markingRead) return;
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    _markingRead = true;
    try {
      await client
          .from('notifications')
          .update({'read': true})
          .eq('user_id', userId)
          .eq('read', false);

      if (!mounted) return;
      setState(() {
        for (final item in _notifications) {
          item['read'] = true;
        }
      });
    } catch (e) {
      AppLogger.debug('Error marking notifications as read: $e');
    } finally {
      _markingRead = false;
    }
  }

  void _subscribe() {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    _channel?.unsubscribe();
    _channel = client
        .channel('notifications_center_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) {
            _scheduleNotificationsReload();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) {
            _scheduleNotificationsReload();
          },
        )
        .subscribe();
  }

  String _formatTimestamp(dynamic raw) {
    final timestamp = parseUtcTimestamp(raw);
    if (timestamp == null) return '';
    return relativeTimeLabel(timestamp);
  }

  @override
  Widget build(BuildContext context) {
    const darkBg = Color(0xFF121212);
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final accentGreen = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkBg,
        iconTheme: IconThemeData(color: accentGreen),
        title: Text(
          t('Benachrichtigungen', 'Notifications'),
          style: GoogleFonts.inter(
            color: textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: RefreshIndicator(
        color: accentGreen,
        onRefresh: () => _loadNotifications(),
        child: _loading
            ? Center(child: CircularProgressIndicator(color: accentGreen))
            : _notifications.isEmpty
            ? ListView(
                children: [
                  const SizedBox(height: 140),
                  Center(
                    child: Text(
                      t(
                        'Noch keine Benachrichtigungen',
                        'No notifications yet',
                      ),
                      style: GoogleFonts.inter(
                        color: textSecondary,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                itemCount: _notifications.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final item = _notifications[index];
                  final type = (item['type'] ?? '').toString();
                  final isUnread = item['read'] != true;
                  final hasPhotoTarget = (item['photo_id'] ?? '')
                      .toString()
                      .trim()
                      .isNotEmpty;
                  final canOpen =
                      hasPhotoTarget || notificationOpensFriendsTab(type);
                  final emoji = notificationEmoji(type);

                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: canOpen ? () => _openNotification(item) : null,
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: cardDark,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isUnread
                                ? accentGreen.withValues(alpha: 0.35)
                                : const Color(0xFF2A2A2A),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: accentGreen.withValues(alpha: 0.14),
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: emoji == '@'
                                  ? Icon(
                                      Icons.alternate_email_rounded,
                                      color: accentGreen,
                                      size: 20,
                                    )
                                  : Text(
                                      emoji,
                                      style: const TextStyle(fontSize: 18),
                                    ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    notificationText(
                                      item,
                                      actorName:
                                          _actorNames[(item['actor_id'] ?? '')
                                              .toString()],
                                      me: Supabase
                                          .instance
                                          .client
                                          .auth
                                          .currentUser
                                          ?.id,
                                    ),
                                    style: GoogleFonts.inter(
                                      color: textPrimary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      height: 1.3,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _formatTimestamp(item['created_at']),
                                    style: GoogleFonts.inter(
                                      color: textSecondary,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (canOpen)
                              const Padding(
                                padding: EdgeInsets.only(left: 8, top: 2),
                                child: Icon(
                                  Icons.chevron_right_rounded,
                                  color: Color(0xFFAAAAAA),
                                ),
                              ),
                            if (isUnread)
                              Container(
                                width: 9,
                                height: 9,
                                margin: const EdgeInsets.only(top: 4, left: 6),
                                decoration: BoxDecoration(
                                  color: accentGreen,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
