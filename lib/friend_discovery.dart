import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'analytics_service.dart';
import 'block_service.dart';
import 'core/app_logger.dart';
import 'shared.dart';

enum FriendRequestResult { sent, alreadyExists, self, blocked, failed }

enum ContactLinkStatus { linked, permissionDenied, unavailable, failed }

class ContactLinkResult {
  final ContactLinkStatus status;
  final int contactsProcessed;

  const ContactLinkResult._(this.status, this.contactsProcessed);

  const ContactLinkResult.linked(int contactsProcessed)
    : this._(ContactLinkStatus.linked, contactsProcessed);
  const ContactLinkResult.permissionDenied()
    : this._(ContactLinkStatus.permissionDenied, 0);
  const ContactLinkResult.unavailable()
    : this._(ContactLinkStatus.unavailable, 0);
  const ContactLinkResult.failed() : this._(ContactLinkStatus.failed, 0);
}

class FriendSuggestionItem {
  final String id;
  final String username;
  final String? profilePicture;
  final bool matchedContact;
  final int mutualFriends;

  const FriendSuggestionItem({
    required this.id,
    required this.username,
    required this.profilePicture,
    required this.matchedContact,
    required this.mutualFriends,
  });
}

class _SuggestionCacheEntry {
  final DateTime createdAt;
  final List<FriendSuggestionItem> items;

  const _SuggestionCacheEntry({required this.createdAt, required this.items});
}

class FriendDiscoveryService {
  static const _contactTokensKeyBase = 'friend_discovery_contact_tokens_v1';
  static const _contactHashesKeyBase = 'friend_discovery_contact_hashes_v1';
  static const _contactsOnboardingSeenKeyBase =
      'friend_discovery_contacts_onboarding_seen_v1';
  static const _suggestionCacheTtl = Duration(minutes: 15);
  static final Map<String, _SuggestionCacheEntry> _suggestionCacheByUser =
      <String, _SuggestionCacheEntry>{};

  static String _tokensKeyForUser(String userId) =>
      '${_contactTokensKeyBase}_$userId';

  static String _hashesKeyForUser(String userId) =>
      '${_contactHashesKeyBase}_$userId';

  /// SHA-256 of a normalized e-mail address. Only these hashes leave the
  /// phone; the server compares them with internal.email_hash() of each
  /// account (same normalization: trimmed, lower case).
  static String contactEmailHash(String email) =>
      sha256.convert(utf8.encode(email.trim().toLowerCase())).toString();

  static String _contactsOnboardingKeyForUser(String userId) =>
      '${_contactsOnboardingSeenKeyBase}_$userId';

  static Future<bool> hasSeenContactsOnboarding(String userId) async {
    if (userId.isEmpty) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_contactsOnboardingKeyForUser(userId)) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> markContactsOnboardingSeen(String userId) async {
    if (userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_contactsOnboardingKeyForUser(userId), true);
    } catch (_) {
      // ignore
    }
  }

  static Future<ContactLinkResult> linkContactsForCurrentUser() async {
    if (kIsWeb) {
      return const ContactLinkResult.unavailable();
    }

    final platform = defaultTargetPlatform;
    final mobilePlatform =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    if (!mobilePlatform) {
      return const ContactLinkResult.unavailable();
    }

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      return const ContactLinkResult.failed();
    }

    try {
      final status = await FlutterContacts.permissions.request(
        PermissionType.read,
      );
      if (status != PermissionStatus.granted &&
          status != PermissionStatus.limited) {
        return const ContactLinkResult.permissionDenied();
      }

      final contacts = await FlutterContacts.getAll(
        properties: {ContactProperty.name, ContactProperty.email},
      );

      final tokens = <String>{};
      final emailHashes = <String>{};
      for (final contact in contacts) {
        _addNameTokens(contact.displayName, tokens);
        final name = contact.name;
        if (name != null) {
          _addNameTokens(name.first, tokens);
          _addNameTokens(name.middle, tokens);
          _addNameTokens(name.last, tokens);
          _addNameTokens(name.nickname, tokens);
        }

        for (final email in contact.emails) {
          final value = email.address.trim().toLowerCase();
          if (value.isEmpty) continue;
          final localPart = value.split('@').first;
          _addNameTokens(localPart, tokens);
          if (value.contains('@')) emailHashes.add(contactEmailHash(value));
        }
      }

      final persistedTokens = tokens.take(600).toList(growable: false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _tokensKeyForUser(userId),
        jsonEncode(persistedTokens),
      );
      await prefs.setString(
        _hashesKeyForUser(userId),
        jsonEncode(emailHashes.take(2000).toList(growable: false)),
      );
      invalidateSuggestionsForUser(userId);

      return ContactLinkResult.linked(contacts.length);
    } catch (_) {
      return const ContactLinkResult.failed();
    }
  }

  static Future<Set<String>> loadLinkedContactTokensForCurrentUser() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return <String>{};
    return _loadLinkedContactTokensForUser(userId);
  }

  static void invalidateSuggestionsForCurrentUser() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    invalidateSuggestionsForUser(userId);
  }

  static void invalidateSuggestionsForUser(String userId) {
    if (userId.isEmpty) return;
    _suggestionCacheByUser.remove(userId);
  }

  static Future<List<FriendSuggestionItem>> loadPersonalizedSuggestions({
    required Set<String> excludeUserIds,
    int limit = 6,
  }) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return const [];

    final baseItems = await _loadOrComputeSuggestionsBase(userId: userId);
    if (baseItems.isEmpty) return const [];

    final blocked = <String>{...excludeUserIds, userId};
    return baseItems
        .where((item) => !blocked.contains(item.id))
        .take(limit)
        .toList(growable: false);
  }

  /// Suggestions come from the server (public.friend_suggestions): contacts
  /// matched by e-mail hash or name, friends of friends, and recently active
  /// public posters. Blocked users and existing friendships are excluded
  /// there.
  static Future<List<FriendSuggestionItem>> _loadOrComputeSuggestionsBase({
    required String userId,
  }) async {
    final now = DateTime.now();
    final cached = _suggestionCacheByUser[userId];
    if (cached != null &&
        cached.createdAt.add(_suggestionCacheTtl).isAfter(now)) {
      return cached.items;
    }

    final hashes = await _loadStringList(_hashesKeyForUser(userId));
    final tokens = await _loadLinkedContactTokensForUser(userId);

    List<dynamic> rows;
    try {
      rows = await Supabase.instance.client.rpc(
        'friend_suggestions',
        params: {
          'p_email_hashes': hashes,
          'p_name_tokens': tokens.toList(growable: false),
          'p_limit': 40,
        },
      );
    } catch (e) {
      AppLogger.debug('Loading friend suggestions failed: $e');
      return cached?.items ?? const [];
    }

    final items = <FriendSuggestionItem>[];
    for (final raw in rows.whereType<Map>()) {
      final id = (raw['id'] ?? '').toString().trim();
      final username = (raw['username'] ?? '').toString().trim();
      if (id.isEmpty || id == userId || username.isEmpty) continue;
      final picture = (raw['profile_picture'] ?? '').toString().trim();
      items.add(
        FriendSuggestionItem(
          id: id,
          username: username,
          profilePicture: picture.isEmpty ? null : picture,
          matchedContact: raw['matched_contact'] == true,
          mutualFriends: (raw['mutual_friends'] as num?)?.toInt() ?? 0,
        ),
      );
    }

    _suggestionCacheByUser[userId] = _SuggestionCacheEntry(
      createdAt: now,
      items: items,
    );
    return items;
  }

  static Future<List<String>> _loadStringList(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.map((e) => e.toString()).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<FriendRequestResult> sendFriendRequest(String friendId) async {
    final client = Supabase.instance.client;
    final currentUserId = client.auth.currentUser?.id;
    if (currentUserId == null || currentUserId.isEmpty) {
      return FriendRequestResult.failed;
    }
    if (friendId.isEmpty || friendId == currentUserId) {
      return FriendRequestResult.self;
    }

    final blockStatus = await BlockService.loadRelationStatus(friendId);
    if (blockStatus.isBlocked) {
      invalidateSuggestionsForUser(currentUserId);
      return FriendRequestResult.blocked;
    }

    try {
      final existing = await client
          .from('friends')
          .select('id')
          .or(
            'and(user_id.eq.$currentUserId,friend_id.eq.$friendId),and(user_id.eq.$friendId,friend_id.eq.$currentUserId)',
          )
          .maybeSingle();
      if (existing != null) {
        invalidateSuggestionsForUser(currentUserId);
        return FriendRequestResult.alreadyExists;
      }

      await client.from('friends').insert({
        'user_id': currentUserId,
        'friend_id': friendId,
        'status': 'pending',
      });
      await AnalyticsService.logInviteSent(type: 'friend_request');
      invalidateSuggestionsForUser(currentUserId);
      return FriendRequestResult.sent;
    } catch (_) {
      return FriendRequestResult.failed;
    }
  }

  static Future<Set<String>> _loadLinkedContactTokensForUser(
    String userId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_tokensKeyForUser(userId));
      if (raw == null || raw.trim().isEmpty) return <String>{};

      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};

      return decoded
          .map((e) => _normalizeToken(e?.toString() ?? ''))
          .where((token) => token.length >= 3)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static void _addNameTokens(String? raw, Set<String> output) {
    if (raw == null) return;
    final normalized = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    if (normalized.isEmpty) return;

    for (final token in normalized.split(' ')) {
      final cleaned = _normalizeToken(token);
      if (cleaned.length >= 3) {
        output.add(cleaned);
      }
    }
  }

  static String _normalizeToken(String raw) {
    return raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '').trim();
  }
}

class FriendSuggestionsRail extends StatefulWidget {
  final Set<String> excludeUserIds;
  final String placement;
  final VoidCallback? onOpenFriendsTab;
  final ValueChanged<String>? onOpenProfile;
  final EdgeInsetsGeometry margin;
  final int suggestionLimit;
  final int seeAllSuggestionLimit;
  final bool showSeeAllButton;

  const FriendSuggestionsRail({
    super.key,
    required this.excludeUserIds,
    required this.placement,
    this.onOpenFriendsTab,
    this.onOpenProfile,
    this.margin = const EdgeInsets.only(bottom: 20),
    this.suggestionLimit = 6,
    this.seeAllSuggestionLimit = 8,
    this.showSeeAllButton = true,
  });

  @override
  State<FriendSuggestionsRail> createState() => _FriendSuggestionsRailState();
}

class _FriendSuggestionsRailState extends State<FriendSuggestionsRail> {
  // Last result per exclude set and limit. The feed throws the rail away
  // when it scrolls far off-screen; with this it comes back at full height
  // in the first frame instead of growing from a spinner, which made the
  // feed jump while scrolling up.
  static final Map<String, List<FriendSuggestionItem>> _lastResults = {};

  Future<List<FriendSuggestionItem>>? _future;
  final Set<String> _dismissedIds = <String>{};
  final Map<String, bool> _followLoading = <String, bool>{};
  String _excludeSignature = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant FriendSuggestionsRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newSignature = _buildExcludeSignature(widget.excludeUserIds);
    if (newSignature != _excludeSignature) {
      _reload();
    }
  }

  String get _resultKey => '$_excludeSignature#${widget.suggestionLimit}';

  void _reload() {
    _excludeSignature = _buildExcludeSignature(widget.excludeUserIds);
    final key = _resultKey;
    _future =
        FriendDiscoveryService.loadPersonalizedSuggestions(
          excludeUserIds: widget.excludeUserIds,
          limit: widget.suggestionLimit,
        ).then((items) {
          _lastResults[key] = items;
          return items;
        });
  }

  String _buildExcludeSignature(Set<String> ids) {
    final sorted = ids.toList()..sort();
    return sorted.join('|');
  }

  Future<void> _openSuggestionsScreen() async {
    final handledIds = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => FriendSuggestionsScreen(
          excludeUserIds: widget.excludeUserIds,
          initiallyDismissedUserIds: _dismissedIds,
          placement: widget.placement,
          onOpenProfile: widget.onOpenProfile,
          suggestionLimit: widget.seeAllSuggestionLimit,
        ),
      ),
    );

    if (!mounted || handledIds == null || handledIds.isEmpty) return;

    setState(() {
      _dismissedIds.addAll(handledIds.where((id) => id.isNotEmpty));
      _reload();
    });
  }

  Future<void> _follow(FriendSuggestionItem item) async {
    if (_followLoading[item.id] == true) return;

    setState(() => _followLoading[item.id] = true);
    final result = await FriendDiscoveryService.sendFriendRequest(item.id);
    if (!mounted) return;

    setState(() {
      _followLoading[item.id] = false;
      if (result == FriendRequestResult.sent ||
          result == FriendRequestResult.alreadyExists) {
        _dismissedIds.add(item.id);
      }
    });

    _showFriendRequestSnackBar(context, result);
  }

  @override
  Widget build(BuildContext context) {
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);

    return FutureBuilder<List<FriendSuggestionItem>>(
      future: _future,
      initialData: _lastResults[_resultKey],
      builder: (context, snapshot) {
        if (!snapshot.hasData &&
            snapshot.connectionState == ConnectionState.waiting) {
          return Padding(
            padding: widget.margin,
            child: const SizedBox(
              height: 18,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          );
        }

        final items = (snapshot.data ?? const <FriendSuggestionItem>[])
            .where((item) => !_dismissedIds.contains(item.id))
            .toList();
        if (items.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: widget.margin,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        t('Personen entdecken', 'Discover people'),
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                        ),
                      ),
                    ),
                    if (widget.showSeeAllButton)
                      TextButton(
                        onPressed: _openSuggestionsScreen,
                        child: Text(
                          t('Alle ansehen', 'See all'),
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: appGreen,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final scale = sideQuestResponsiveScale(
                    context,
                    minScale: 0.78,
                    maxScale: 1.0,
                  );
                  final cardHeight =
                      ((constraints.maxWidth < 360 ? 244.0 : 256.0) * scale)
                          .clamp(234.0, 260.0);
                  final cardWidth =
                      ((constraints.maxWidth < 360 ? 164.0 : 180.0) * scale)
                          .clamp(152.0, 180.0);
                  final cardGap = (12 * scale).clamp(10.0, 12.0);

                  return SizedBox(
                    height: cardHeight,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: items.length,
                      separatorBuilder: (_, _) => SizedBox(width: cardGap),
                      itemBuilder: (context, i) {
                        final item = items[i];
                        final isLoading = _followLoading[item.id] == true;
                        final canOpenProfile = widget.onOpenProfile != null;

                        return SizedBox(
                          width: cardWidth,
                          child: _FriendSuggestionCard(
                            item: item,
                            isLoading: isLoading,
                            onDismiss: () {
                              setState(() => _dismissedIds.add(item.id));
                            },
                            onFollow: () => _follow(item),
                            onOpenProfile: canOpenProfile
                                ? () => widget.onOpenProfile!(item.id)
                                : null,
                            cardDark: cardDark,
                            textPrimary: textPrimary,
                            textSecondary: textSecondary,
                            closeIconColor: appGreen.withValues(alpha: 0.9),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

String _friendSuggestionSubtitle(FriendSuggestionItem item) {
  if (item.matchedContact) {
    return t('Aus deinen Kontakten', 'From your contacts');
  }
  if (item.mutualFriends > 0) {
    return t(
      '${item.mutualFriends} gemeinsame Freunde',
      '${item.mutualFriends} mutual friends',
    );
  }
  return t('Für dich vorgeschlagen', 'Suggested for you');
}

class _FriendSuggestionCard extends StatelessWidget {
  final FriendSuggestionItem item;
  final bool isLoading;
  final VoidCallback onDismiss;
  final VoidCallback onFollow;
  final VoidCallback? onOpenProfile;
  final Color cardDark;
  final Color textPrimary;
  final Color textSecondary;
  final Color closeIconColor;

  const _FriendSuggestionCard({
    required this.item,
    required this.isLoading,
    required this.onDismiss,
    required this.onFollow,
    required this.cardDark,
    required this.textPrimary,
    required this.textSecondary,
    required this.closeIconColor,
    this.onOpenProfile,
  });

  @override
  Widget build(BuildContext context) {
    final scale = sideQuestResponsiveScale(
      context,
      minScale: 0.78,
      maxScale: 1.0,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : 180.0 * scale;
        final cardHeight =
            constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : 250.0 * scale;
        final compactCard = cardWidth < 165 || cardHeight < 238;
        final horizontalPadding = (compactCard ? 10.0 : 12.0) * scale;
        final topPadding = (compactCard ? 6.0 : 8.0) * scale;
        final bottomPadding = (compactCard ? 10.0 : 12.0) * scale;
        final closeIconSize = (compactCard ? 17.0 : 18.0) * scale;
        final avatarRadius = ((compactCard ? 34.0 : 40.0) * scale).clamp(
          30.0,
          40.0,
        );
        final avatarDiameter = (avatarRadius * 2).round();
        final avatarGap = (compactCard ? 10.0 : 12.0) * scale;
        final usernameSize = ((compactCard ? 18.0 : 20.0) * scale).clamp(
          17.0,
          20.0,
        );
        final subtitleSize = ((compactCard ? 12.0 : 13.0) * scale).clamp(
          11.5,
          13.0,
        );
        final subtitleTopGap = (compactCard ? 3.0 : 4.0) * scale;
        final buttonHeight = ((compactCard ? 39.0 : 42.0) * scale).clamp(
          38.0,
          42.0,
        );
        final buttonFontSize = ((compactCard ? 14.0 : 15.0) * scale).clamp(
          13.0,
          15.0,
        );

        return Container(
          decoration: BoxDecoration(
            color: cardDark,
            borderRadius: BorderRadius.circular(18 * scale),
            border: Border.all(color: const Color(0xFF2A2A2A)),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              topPadding,
              horizontalPadding,
              bottomPadding,
            ),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onDismiss,
                    child: Padding(
                      padding: EdgeInsets.all(4 * scale),
                      child: Icon(
                        Icons.close,
                        size: closeIconSize,
                        color: closeIconColor,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onOpenProfile,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: avatarRadius,
                          backgroundColor: Colors.black,
                          backgroundImage: item.profilePicture != null
                              ? sideQuestCachedImageProvider(
                                  item.profilePicture!,
                                  cacheWidth: sideQuestCacheWidth(
                                    context,
                                    avatarDiameter.toDouble(),
                                  ),
                                  cacheHeight: sideQuestCacheWidth(
                                    context,
                                    avatarDiameter.toDouble(),
                                  ),
                                )
                              : null,
                          child: item.profilePicture == null
                              ? Text(
                                  item.username.isNotEmpty
                                      ? item.username[0].toUpperCase()
                                      : 'U',
                                  style: GoogleFonts.inter(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: avatarRadius * 0.6,
                                  ),
                                )
                              : null,
                        ),
                        SizedBox(height: avatarGap),
                        Text(
                          item.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: usernameSize,
                            fontWeight: FontWeight.w700,
                            color: textPrimary,
                          ),
                        ),
                        SizedBox(height: subtitleTopGap),
                        Flexible(
                          child: Center(
                            child: Text(
                              _friendSuggestionSubtitle(item),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: subtitleSize,
                                fontWeight: FontWeight.w600,
                                color: textSecondary,
                                height: 1.2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 6 * scale),
                SizedBox(
                  width: double.infinity,
                  height: buttonHeight,
                  child: ElevatedButton(
                    onPressed: isLoading ? null : onFollow,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: appGreen,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12 * scale),
                      ),
                    ),
                    child: isLoading
                        ? SizedBox(
                            width: 18 * scale,
                            height: 18 * scale,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : Text(
                            t('Folgen', 'Follow'),
                            style: GoogleFonts.inter(
                              fontSize: buttonFontSize,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

void _showFriendRequestSnackBar(
  BuildContext context,
  FriendRequestResult result,
) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;

  String message;
  switch (result) {
    case FriendRequestResult.sent:
      message = t('Freundschaftsanfrage gesendet', 'Friend request sent');
      break;
    case FriendRequestResult.alreadyExists:
      message = t('Anfrage existiert bereits', 'Request already exists');
      break;
    case FriendRequestResult.self:
      message = t(
        'Du kannst dich nicht selbst folgen',
        'You cannot follow yourself',
      );
      break;
    case FriendRequestResult.blocked:
      message = t(
        'Diese Person ist blockiert oder hat dich blockiert',
        'This person is blocked or has blocked you',
      );
      break;
    case FriendRequestResult.failed:
      message = t('Fehler beim Senden der Anfrage', 'Error sending request');
      break;
  }

  messenger.showSnackBar(SnackBar(content: Text(message)));
}

class FriendSuggestionsScreen extends StatefulWidget {
  final Set<String> excludeUserIds;
  final Set<String> initiallyDismissedUserIds;
  final String placement;
  final ValueChanged<String>? onOpenProfile;
  final int suggestionLimit;

  const FriendSuggestionsScreen({
    super.key,
    required this.excludeUserIds,
    required this.initiallyDismissedUserIds,
    required this.placement,
    this.onOpenProfile,
    this.suggestionLimit = 8,
  });

  @override
  State<FriendSuggestionsScreen> createState() =>
      _FriendSuggestionsScreenState();
}

class _FriendSuggestionsScreenState extends State<FriendSuggestionsScreen> {
  Future<List<FriendSuggestionItem>>? _future;
  final Set<String> _dismissedIds = <String>{};
  final Set<String> _handledIds = <String>{};
  final Map<String, bool> _followLoading = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _dismissedIds.addAll(widget.initiallyDismissedUserIds);
    FriendDiscoveryService.invalidateSuggestionsForCurrentUser();
    _reload();
  }

  void _reload() {
    _future = FriendDiscoveryService.loadPersonalizedSuggestions(
      excludeUserIds: widget.excludeUserIds,
      limit: widget.suggestionLimit,
    );
  }

  void _dismissSuggestion(String userId) {
    if (userId.isEmpty) return;
    setState(() {
      _dismissedIds.add(userId);
      _handledIds.add(userId);
    });
  }

  Future<void> _follow(FriendSuggestionItem item) async {
    if (_followLoading[item.id] == true) return;

    setState(() => _followLoading[item.id] = true);
    final result = await FriendDiscoveryService.sendFriendRequest(item.id);
    if (!mounted) return;

    setState(() {
      _followLoading[item.id] = false;
      if (result == FriendRequestResult.sent ||
          result == FriendRequestResult.alreadyExists) {
        _dismissedIds.add(item.id);
        _handledIds.add(item.id);
      }
    });

    _showFriendRequestSnackBar(context, result);
  }

  void _close() {
    Navigator.of(context).pop(_handledIds.toList(growable: false));
  }

  @override
  Widget build(BuildContext context) {
    const darkBg = Color(0xFF121212);
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);

    return PopScope<List<String>>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _close();
      },
      child: Scaffold(
        backgroundColor: darkBg,
        appBar: AppBar(
          backgroundColor: darkBg,
          elevation: 0,
          centerTitle: false,
          automaticallyImplyLeading: false,
          titleSpacing: 20,
          title: Text(
            t('Personen entdecken', 'Discover people'),
            style: GoogleFonts.inter(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: textPrimary,
            ),
          ),
          actions: [
            IconButton(
              onPressed: _close,
              icon: const Icon(Icons.close_rounded, color: appGreen),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: FutureBuilder<List<FriendSuggestionItem>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              );
            }

            final items = (snapshot.data ?? const <FriendSuggestionItem>[])
                .where((item) => !_dismissedIds.contains(item.id))
                .toList(growable: false);

            if (items.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 120, 24, 24),
                children: [
                  Center(
                    child: Text(
                      t('Zurzeit keine Vorschläge', 'No suggestions right now'),
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        color: textSecondary,
                      ),
                    ),
                  ),
                ],
              );
            }

            return LayoutBuilder(
              builder: (context, constraints) {
                final scale = sideQuestResponsiveScale(
                  context,
                  minScale: 0.78,
                  maxScale: 1.0,
                );
                final horizontalPadding = constraints.maxWidth < 360
                    ? 12.0
                    : 16.0;
                final spacing =
                    (constraints.maxWidth < 360 ? 10.0 : 12.0) * scale;
                final gridWidth =
                    constraints.maxWidth - (horizontalPadding * 2);
                final crossAxisCount = gridWidth < 290 ? 1 : 2;
                final cardWidth =
                    (gridWidth - (spacing * (crossAxisCount - 1))) /
                    crossAxisCount;
                final cardHeight = math.max(
                  238.0 * scale,
                  cardWidth * (crossAxisCount == 1 ? 1.15 : 1.58),
                );

                return GridView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    12 * scale,
                    horizontalPadding,
                    28 * scale,
                  ),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                    mainAxisExtent: cardHeight,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isLoading = _followLoading[item.id] == true;
                    final canOpenProfile = widget.onOpenProfile != null;

                    return _FriendSuggestionCard(
                      item: item,
                      isLoading: isLoading,
                      onDismiss: () => _dismissSuggestion(item.id),
                      onFollow: () => _follow(item),
                      onOpenProfile: canOpenProfile
                          ? () => widget.onOpenProfile!(item.id)
                          : null,
                      cardDark: cardDark,
                      textPrimary: textPrimary,
                      textSecondary: textSecondary,
                      closeIconColor: appGreen,
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}
