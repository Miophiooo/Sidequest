import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'block_service.dart';
import 'core/app_logger.dart';
import 'core/error_mapper.dart';
import 'core/signed_storage_media.dart';
import 'daily_challenges.dart';
import 'london_time.dart';
import 'friend_discovery.dart';
import 'gesture_cropper.dart';
import 'image_compression.dart';
import 'image_validation.dart';
import 'notifications_center.dart';
import 'settings_screen.dart';
import 'features/media/post_media.dart';
import 'shared.dart';
import 'widgets/profile_stat_chip.dart';
import 'widgets/crowd_favorite_badge.dart';

/// Cached Inter TextStyle – avoids repeated font-family lookups in build().
final TextStyle _inter = GoogleFonts.inter(fontWeight: FontWeight.w700);

class ProfileScreen extends StatefulWidget {
  final String? userId;

  const ProfileScreen({super.key, this.userId});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final picker = ImagePicker();
  bool _sendingFriendRequest = false;
  bool _friendRequestJustSent = false;
  late Future<Map<String, dynamic>> _profileFuture;

  /// Downloads a post image and writes it into the device's photo gallery.
  Future<void> _savePhotoToDevice(String url) async {
    if (url.isEmpty) return;
    try {
      if (!await Gal.hasAccess()) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  t('Kein Zugriff auf Fotos', 'No access to Photos'),
                ),
              ),
            );
          }
          return;
        }
      }

      final httpClient = HttpClient();
      Uint8List bytes;
      try {
        // Post images live in the private `photos` bucket — sign before fetch.
        final request = await httpClient.getUrl(
          Uri.parse(await SignedStorageUrls.resolve(url)),
        );
        final response = await request.close();
        if (response.statusCode != 200) {
          throw Exception('HTTP ${response.statusCode}');
        }
        bytes = await consolidateHttpClientResponseBytes(response);
      } finally {
        httpClient.close();
      }

      await Gal.putImageBytes(bytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('In Fotos gespeichert', 'Saved to Photos')),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('Speichern fehlgeschlagen', 'Could not save photo'),
            ),
          ),
        );
      }
    }
  }

  Future<void> _confirmDeleteOwnPhoto(String photoId) async {
    if (photoId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          t('Post löschen?', 'Delete post?'),
          style: _inter.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          t(
            'Dieser Post wird dauerhaft entfernt.',
            'This post will be permanently removed.',
          ),
          style: _inter.copyWith(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t('Abbrechen', 'Cancel'),
              style: _inter.copyWith(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t('Löschen', 'Delete'),
              style: _inter.copyWith(
                color: Colors.redAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _deleteOwnPhoto(photoId);
    }
  }

  Future<void> _deleteOwnPhoto(String photoId) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || photoId.isEmpty) return;

    try {
      final photoRow = await client
          .from('photos')
          .select('url, thumb_url, live_photo_clip_path')
          .eq('id', photoId)
          .eq('user_id', userId)
          .maybeSingle();

      if (photoRow == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(t('Post nicht gefunden', 'Post not found')),
            ),
          );
        }
        return;
      }

      // Image, thumbnail and live clip are removed after the row is gone.
      final storagePaths = postStoragePaths(photoRow);

      // Best-effort cleanup of related rows before deleting the post itself.
      try {
        await client.from('comment_likes').delete().eq('photo_id', photoId);
      } catch (_) {}
      await client.from('comments').delete().eq('photo_id', photoId);
      await client.from('likes').delete().eq('photo_id', photoId);

      await client
          .from('photos')
          .delete()
          .eq('id', photoId)
          .eq('user_id', userId);

      if (storagePaths.isNotEmpty) {
        try {
          await client.storage.from('photos').remove(storagePaths);
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _profileFuture = loadProfile();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Post gelöscht', 'Post deleted'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ErrorMapper.describe(
              e,
              whatDe: 'Löschen fehlgeschlagen',
              whatEn: 'Delete failed',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _removeFriendFromProfile(String targetUserId) async {
    if (targetUserId.isEmpty) return;

    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          t('Freund entfernen?', 'Remove friend?'),
          style: _inter.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          t(
            'Ihr seid danach nicht mehr befreundet.',
            'You will no longer be friends afterwards.',
          ),
          style: _inter.copyWith(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t('Abbrechen', 'Cancel'),
              style: _inter.copyWith(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t('Entfernen', 'Remove'),
              style: _inter.copyWith(
                color: const Color(0xFFFFB74D),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      await client
          .from('friends')
          .delete()
          .or(
            'and(user_id.eq.$userId,friend_id.eq.$targetUserId),and(user_id.eq.$targetUserId,friend_id.eq.$userId)',
          );
      FriendDiscoveryService.invalidateSuggestionsForCurrentUser();
      if (!mounted) return;
      setState(() {
        _friendRequestJustSent = false;
        _profileFuture = loadProfile();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Freund entfernt', 'Friend removed'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ErrorMapper.describe(
              e,
              whatDe: 'Fehler beim Entfernen',
              whatEn: 'Error removing friend',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _blockUserFromProfile(String targetUserId) async {
    if (targetUserId.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          t('Nutzer blockieren?', 'Block user?'),
          style: _inter.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          t(
            'Die Person wird aus Vorschlägen entfernt und kann dich ebenfalls nicht mehr als Vorschlag sehen.',
            'This person will disappear from suggestions and will also no longer see you as a suggestion.',
          ),
          style: _inter.copyWith(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t('Abbrechen', 'Cancel'),
              style: _inter.copyWith(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t('Blockieren', 'Block'),
              style: _inter.copyWith(
                color: Colors.redAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      await BlockService.blockUser(targetUserId);
      FriendDiscoveryService.invalidateSuggestionsForCurrentUser();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Nutzer blockiert', 'User blocked'))),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ErrorMapper.describe(
              e,
              whatDe: 'Blockieren fehlgeschlagen',
              whatEn: 'Blocking failed',
            ),
          ),
        ),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _profileFuture = loadProfile();
    postDataRefreshNotifier.addListener(_onPostDataChanged);
  }

  @override
  void dispose() {
    postDataRefreshNotifier.removeListener(_onPostDataChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _profileFuture = loadProfile();
    }
  }

  void _onPostDataChanged() {
    if (!mounted) return;
    setState(() {
      _profileFuture = loadProfile();
    });
  }

  Future<void> _sendFriendRequestFromProfile(String targetUserId) async {
    if (targetUserId.isEmpty || _sendingFriendRequest) return;
    setState(() => _sendingFriendRequest = true);

    try {
      final result = await FriendDiscoveryService.sendFriendRequest(
        targetUserId,
      );
      if (!mounted) return;

      switch (result) {
        case FriendRequestResult.sent:
          setState(() => _friendRequestJustSent = true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t('Freundschaftsanfrage gesendet', 'Friend request sent'),
              ),
            ),
          );
          break;
        case FriendRequestResult.alreadyExists:
          setState(() => _friendRequestJustSent = true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t('Es gibt bereits eine Anfrage', 'A request already exists'),
              ),
            ),
          );
          break;
        case FriendRequestResult.self:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Du kannst dich nicht selbst hinzufügen',
                  'You cannot add yourself',
                ),
              ),
            ),
          );
          break;
        case FriendRequestResult.blocked:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Diese Person ist blockiert oder hat dich blockiert',
                  'This person is blocked or has blocked you',
                ),
              ),
            ),
          );
          break;
        case FriendRequestResult.failed:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Freundschaftsanfrage konnte nicht gesendet werden',
                  'Could not send friend request',
                ),
              ),
            ),
          );
          break;
      }
    } finally {
      if (mounted) {
        setState(() => _sendingFriendRequest = false);
      }
    }
  }

  Future<bool> _isFriendWith(String currentUserId, String otherUserId) async {
    if (currentUserId == otherUserId) return true;

    final client = Supabase.instance.client;

    final direct = await client
        .from('friends')
        .select('id')
        .eq('status', 'accepted')
        .eq('user_id', currentUserId)
        .eq('friend_id', otherUserId)
        .limit(1);
    if (direct.isNotEmpty) return true;

    final reverse = await client
        .from('friends')
        .select('id')
        .eq('status', 'accepted')
        .eq('user_id', otherUserId)
        .eq('friend_id', currentUserId)
        .limit(1);
    return reverse.isNotEmpty;
  }

  Map<String, String> _dailyChallengeForPhoto(String? createdAtIso) {
    if (createdAtIso == null) {
      return {
        'title': t('Daily Quest', 'Daily Quest'),
        'description': t(
          'Quest-Beschreibung nicht verfügbar.',
          'Quest description unavailable.',
        ),
      };
    }

    final parsed = parseUtcTimestamp(createdAtIso);
    if (parsed == null) {
      return {
        'title': t('Daily Quest', 'Daily Quest'),
        'description': t(
          'Quest-Beschreibung nicht verfügbar.',
          'Quest description unavailable.',
        ),
      };
    }

    final londonDay = activeLondonChallengeDayFromUtc(parsed);
    final days = challengeDayIndexForLondonDay(londonDay);
    var idx = days % kDailyChallenges.length;
    if (idx < 0) idx += kDailyChallenges.length;

    final challenge = kDailyChallenges[idx];
    final emoji = (challenge['emoji'] ?? '').toString();
    final title = t(
      challenge['de']?.toString() ?? 'Daily Quest',
      challenge['en']?.toString() ?? 'Daily Quest',
    );
    final description = t(
      challenge['desc_de']?.toString() ?? '',
      challenge['desc_en']?.toString() ?? '',
    );

    return {
      'title': emoji.isEmpty ? title : '$emoji $title',
      'description': description,
    };
  }

  /// Replaces the locally computed quest of each post with the quest that
  /// was actually planned for its day (daily_quest_schedule), in one request.
  /// The local rotation stays as the fallback (offline, very old posts).
  Future<void> _applyScheduledQuests(List<Map<String, dynamic>> photos) async {
    final dayOf = <Map<String, dynamic>, String>{};
    for (final photo in photos) {
      final created = parseUtcTimestamp(photo['created_at']);
      if (created == null) continue;
      dayOf[photo] = londonDateStrFromLondonDay(
        activeLondonChallengeDayFromUtc(created),
      );
    }
    if (dayOf.isEmpty) return;
    try {
      final rows = await Supabase.instance.client
          .from('daily_quest_schedule')
          .select('london_date, daily_quests(emoji, title_de, title_en, desc_de, desc_en)')
          .inFilter('london_date', dayOf.values.toSet().toList());
      final questByDay = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final quest = row['daily_quests'];
        if (quest is Map) {
          questByDay[(row['london_date'] ?? '').toString()] =
              Map<String, dynamic>.from(quest);
        }
      }
      for (final entry in dayOf.entries) {
        final quest = questByDay[entry.value];
        if (quest == null) continue;
        final emoji = (quest['emoji'] ?? '').toString();
        final title = t(
          (quest['title_de'] ?? '').toString(),
          (quest['title_en'] ?? '').toString(),
        );
        entry.key['daily_title'] = emoji.isEmpty ? title : '$emoji $title';
        entry.key['daily_description'] = t(
          (quest['desc_de'] ?? '').toString(),
          (quest['desc_en'] ?? '').toString(),
        );
      }
    } catch (e) {
      AppLogger.debug('Loading planned quests failed (using fallback): $e');
    }
  }

  Future<Map<String, int>> _loadPvpWinRate(String userId) async {
    final client = Supabase.instance.client;
    try {
      final completedChallenges = await client
          .from('challenges')
          .select('id, challenger_id, challenged_id, winner_id')
          .or('challenger_id.eq.$userId,challenged_id.eq.$userId')
          .not('completed_at', 'is', null);

      if (completedChallenges.isEmpty) {
        return {'wins': 0, 'losses': 0, 'total': 0};
      }

      final challengeIds = completedChallenges
          .map((c) => (c['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();

      if (challengeIds.isEmpty) {
        return {'wins': 0, 'losses': 0, 'total': 0};
      }

      final photos = await client
          .from('photos')
          .select('challenge_id, user_id')
          .inFilter('challenge_id', challengeIds);

      final photosByChallenge = <String, Set<String>>{};
      for (final photo in photos) {
        final cid = (photo['challenge_id'] ?? '').toString();
        final uid = (photo['user_id'] ?? '').toString();
        if (cid.isNotEmpty && uid.isNotEmpty) {
          photosByChallenge.putIfAbsent(cid, () => <String>{}).add(uid);
        }
      }

      int wins = 0;
      int losses = 0;

      for (final challenge in completedChallenges) {
        final challengeId = (challenge['id'] ?? '').toString();
        final challengerId = (challenge['challenger_id'] ?? '').toString();
        final challengedId = (challenge['challenged_id'] ?? '').toString();
        final winnerId = challenge['winner_id']?.toString();

        final posters = photosByChallenge[challengeId] ?? {};
        final bothPosted =
            posters.contains(challengerId) && posters.contains(challengedId);

        if (!bothPosted) continue;
        if (winnerId == null || winnerId.isEmpty) continue;

        if (winnerId == userId) {
          wins++;
        } else {
          losses++;
        }
      }

      final total = wins + losses;
      return {'wins': wins, 'losses': losses, 'total': total};
    } catch (e) {
      AppLogger.debug('Error loading PVP win rate: $e');
      return {'wins': 0, 'losses': 0, 'total': 0};
    }
  }

  Future<Map<String, dynamic>> loadProfile() async {
    final client = Supabase.instance.client;
    final currentUserId = client.auth.currentUser!.id;
    final targetUserId = widget.userId ?? currentUserId;
    Map<String, dynamic>? friendship;
    var friendshipStatus = '';
    var isIncomingPending = false;
    var blockStatus = const BlockRelationStatus(
      blockedByMe: false,
      blockedMe: false,
    );

    if (targetUserId != currentUserId) {
      blockStatus = await BlockService.loadRelationStatus(targetUserId);
      try {
        final existing = await client
            .from('friends')
            .select('status, user_id, friend_id')
            .or(
              'and(user_id.eq.$currentUserId,friend_id.eq.$targetUserId),and(user_id.eq.$targetUserId,friend_id.eq.$currentUserId)',
            )
            .maybeSingle();
        if (existing != null) {
          friendship = Map<String, dynamic>.from(existing);
        }
      } catch (_) {
        // ignore
      }

      friendshipStatus = (friendship?['status'] ?? '').toString();
      isIncomingPending =
          friendshipStatus == 'pending' &&
          (friendship?['friend_id'] ?? '').toString() == currentUserId;
    }

    if (targetUserId != currentUserId) {
      if (blockStatus.isBlocked) {
        final profile = await client
            .from("users_profile")
            .select("id, username, profile_picture")
            .eq("id", targetUserId)
            .single();
        return {
          ...Map<String, dynamic>.from(profile),
          'limited_view': true,
          'today_photo_count': 0,
          'all_photo_count': 0,
          'joker': 0,
          'own_photos': const <Map<String, dynamic>>[],
          'friendship_status': friendshipStatus,
          'friend_request_incoming': isIncomingPending,
          'is_blocked': true,
          'blocked_by_me': blockStatus.blockedByMe,
        };
      }

      final canView = await _isFriendWith(currentUserId, targetUserId);
      if (!canView) {
        final profile = await client
            .from("users_profile")
            .select("id, username, profile_picture")
            .eq("id", targetUserId)
            .single();
        final mutualFriends = await _loadMutualFriends(
          currentUserId,
          targetUserId,
        );
        return {
          ...Map<String, dynamic>.from(profile),
          'limited_view': true,
          'today_photo_count': 0,
          'all_photo_count': 0,
          'joker': 0,
          'own_photos': const <Map<String, dynamic>>[],
          'friendship_status': friendshipStatus,
          'friend_request_incoming': isIncomingPending,
          'is_blocked': false,
          'blocked_by_me': false,
          'mutual_friends': mutualFriends,
        };
      }
    }

    final profile = await client
        .from("users_profile")
        .select()
        .eq("id", targetUserId)
        .single();

    // Display only the 3 most recent NON-challenge photos. We pull a small
    // batch (15) to absorb any challenge-photos that get filtered out below,
    // then slice to 3. The total count is fetched separately as a HEAD-only
    // query (no row payload).
    var photosQuery = client
        .from("photos")
        .select(
          "id, url, thumb_url, created_at, challenge_description, is_public, is_challenge_photo, challenge_id, is_collab_extension, collab_base_photo_id",
        )
        .eq("user_id", targetUserId);

    if (targetUserId != currentUserId) {
      photosQuery = photosQuery.eq("is_public", true);
    }

    final ownPhotosRaw = await photosQuery
        .order("created_at", ascending: false)
        .limit(15);

    final ownPhotos = (ownPhotosRaw as List<dynamic>)
        .whereType<Map>()
        .map<Map<String, dynamic>?>((row) {
          final map = Map<String, dynamic>.from(row);
          final rawIsChallenge = map['is_challenge_photo'];
          final hasChallengeFlag =
              rawIsChallenge == true ||
              rawIsChallenge == 1 ||
              rawIsChallenge == 'true' ||
              rawIsChallenge == 't';
          final hasChallengeId = map['challenge_id'] != null;
          final isChallengePhoto = hasChallengeFlag || hasChallengeId;
          if (isChallengePhoto) {
            return null;
          }

          // Hide collab/combo extensions — those are addons to someone else's
          // daily post, not standalone daily-quest entries from this user.
          final rawIsExtension = map['is_collab_extension'];
          final isCollabExtension =
              rawIsExtension == true ||
              rawIsExtension == 1 ||
              rawIsExtension == 'true' ||
              rawIsExtension == 't' ||
              ((map['collab_base_photo_id'] ?? '').toString().trim().isNotEmpty);
          if (isCollabExtension) {
            return null;
          }

          final daily = _dailyChallengeForPhoto(map['created_at']?.toString());
          return {
            ...map,
            'daily_title': daily['title'],
            'daily_description': daily['description'],
          };
        })
        .whereType<Map<String, dynamic>>()
        .where((row) => ((row['url'] as String?) ?? '').isNotEmpty)
        .take(3) // Only show the latest 3 in the profile grid
        .toList(growable: false);
    await _applyScheduledQuests(ownPhotos);

    // Cheap head-only count of all non-challenge photos (no row payload).
    int totalPostCount = 0;
    try {
      var countQuery = client
          .from("photos")
          .count(CountOption.exact)
          .eq("user_id", targetUserId)
          .or("is_challenge_photo.is.null,is_challenge_photo.eq.false")
          .filter("challenge_id", "is", null)
          // Match the row-fetch filter: hide collab extensions from the count
          // so the grid header doesn't show "5 posts" when only 3 are
          // standalone daily-quest entries.
          .or("is_collab_extension.is.null,is_collab_extension.eq.false")
          .filter("collab_base_photo_id", "is", null);
      if (targetUserId != currentUserId) {
        countQuery = countQuery.eq("is_public", true);
      }
      totalPostCount = await countQuery;
    } catch (_) {
      // Fallback: if the count query fails (e.g. ambiguous schema), use the
      // visible-batch length as a lower bound rather than crashing the screen.
      totalPostCount = ownPhotos.length;
    }

    final today = DateTime.now().toIso8601String().split('T')[0];
    final todayPhotoCount = ownPhotos.where((photo) {
      final createdAt = parseUtcTimestamp(photo['created_at']);
      if (createdAt == null) return false;
      final localDate = createdAt.toLocal().toIso8601String().split('T')[0];
      return localDate == today;
    }).length;

    final jokerCount = profile['joker'] ?? 0;

    final pvpStats = await _loadPvpWinRate(targetUserId);
    final pvpWins = pvpStats['wins'] ?? 0;
    final pvpTotal = pvpStats['total'] ?? 0;
    final pvpWinRate = pvpTotal > 0 ? (pvpWins * 100 / pvpTotal).round() : -1;

    // Mutual friends: friends of mine who are also friends of the viewed
    // profile. Only fetched when viewing somebody else's profile.
    final mutualFriends = targetUserId == currentUserId
        ? const <Map<String, dynamic>>[]
        : await _loadMutualFriends(currentUserId, targetUserId);

    return {
      ...profile,
      'limited_view': false,
      'today_photo_count': todayPhotoCount,
      'all_photo_count': totalPostCount,
      'joker': jokerCount,
      'own_photos': ownPhotos,
      'friendship_status': friendshipStatus,
      'friend_request_incoming': isIncomingPending,
      'is_blocked': blockStatus.isBlocked,
      'blocked_by_me': blockStatus.blockedByMe,
      'pvp_win_rate': pvpWinRate,
      'mutual_friends': mutualFriends,
    };
  }

  /// Friends of [currentUserId] who are also friends of [targetUserId]. Two
  /// `friends` round trips (one per side), intersected client-side. Returns
  /// `[{id, username, profile_picture}]`, capped at a few entries — callers
  /// only render 2 avatars + a "+N weitere" count.
  Future<List<Map<String, dynamic>>> _loadMutualFriends(
    String currentUserId,
    String targetUserId,
  ) async {
    if (currentUserId.isEmpty || targetUserId.isEmpty) return const [];
    final client = Supabase.instance.client;
    try {
      final myFriendships = await client
          .from('friends')
          .select('user_id, friend_id')
          .or('user_id.eq.$currentUserId,friend_id.eq.$currentUserId')
          .eq('status', 'accepted');
      final mySet = <String>{};
      for (final row in myFriendships) {
        final a = (row['user_id'] ?? '').toString();
        final b = (row['friend_id'] ?? '').toString();
        if (a == currentUserId && b.isNotEmpty && b != targetUserId) {
          mySet.add(b);
        }
        if (b == currentUserId && a.isNotEmpty && a != targetUserId) {
          mySet.add(a);
        }
      }
      if (mySet.isEmpty) return const [];

      final theirFriendships = await client
          .from('friends')
          .select('user_id, friend_id')
          .or('user_id.eq.$targetUserId,friend_id.eq.$targetUserId')
          .eq('status', 'accepted');
      final mutualIds = <String>{};
      for (final row in theirFriendships) {
        final a = (row['user_id'] ?? '').toString();
        final b = (row['friend_id'] ?? '').toString();
        final other = a == targetUserId ? b : a;
        if (other.isNotEmpty && mySet.contains(other)) {
          mutualIds.add(other);
        }
      }
      if (mutualIds.isEmpty) return const [];

      final profiles = await client
          .from('users_profile')
          .select('id, username, profile_picture')
          .inFilter('id', mutualIds.toList());
      return (profiles as List)
          .map((raw) => Map<String, dynamic>.from(raw as Map))
          .where((row) => (row['username'] ?? '').toString().trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> updateProfilePicture() async {
    final source = await _pickProfileImageSource();
    if (source == null) return;

    XFile? file;
    try {
      file = await picker.pickImage(source: source);
    } on PlatformException catch (e) {
      AppLogger.debug(
        'pickImage failed: code=${e.code} message=${e.message} details=${e.details}',
      );
      if (mounted) {
        final msg =
            (e.code == 'photo_access_denied' ||
                e.code == 'camera_access_denied')
            ? t(
                'Kein Zugriff auf Kamera oder Fotos. Bitte in den Einstellungen erlauben.',
                'No camera or photo access. Please allow it in Settings.',
              )
            : t(
                'Bild konnte nicht ausgewählt werden (${e.code}).',
                'Could not pick image (${e.code}).',
              );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
      return;
    } catch (e) {
      AppLogger.debug('pickImage failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
      return;
    }

    final pickedFile = file;
    if (pickedFile == null) return;
    if (!mounted) return;

    File? croppedFile;
    try {
      croppedFile = await Navigator.of(context).push<File>(
        MaterialPageRoute(
          builder: (_) => GestureCropperScreen.profile(
            sourcePath: pickedFile.path,
            title: t('Profilbild zuschneiden', 'Crop profile photo'),
            cancelLabel: t('Abbrechen', 'Cancel'),
            confirmLabel: t('Fertig', 'Done'),
          ),
        ),
      );
    } catch (e) {
      AppLogger.debug('profile crop failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
      return;
    }

    if (croppedFile == null) return;
    final fileForUpload = croppedFile;

    // Validate image before upload (size + MIME type)
    final imgCheck = await validateImageFile(fileForUpload.path);
    if (!imgCheck.isValid) {
      if (mounted) {
        final msg = imgCheck.error == ImageValidationError.tooLarge
            ? t(
                'Bild ist zu groß (max. 25 MB)',
                'Image is too large (max 25 MB)',
              )
            : t(
                'Ungültiges Bildformat (nur JPEG/PNG)',
                'Invalid image format (JPEG/PNG only)',
              );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
      return;
    }

    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;

      final fileName = "profile_$userId.jpg";
      try {
        await client.storage.from("profile_pictures").remove([fileName]);
      } catch (_) {}

      final compressedAvatar = await compressAvatarForUpload(
        fileForUpload.path,
      );
      await client.storage
          .from("profile_pictures")
          .upload(fileName, compressedAvatar);

      final publicUrl = client.storage
          .from("profile_pictures")
          .getPublicUrl(fileName);

      // Cache-bust so the updated image shows immediately.
      final cacheBustedUrl =
          '$publicUrl?v=${DateTime.now().millisecondsSinceEpoch}';

      await client
          .from("users_profile")
          .update({"profile_picture": cacheBustedUrl})
          .eq("id", userId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t("Profilbild aktualisiert!", "Profile picture updated!"),
            ),
          ),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
    }
  }

  Future<ImageSource?> _pickProfileImageSource() async {
    if (!mounted) return null;
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A3A3A),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.photo_library_outlined,
                    color: Colors.white,
                  ),
                  title: Text(
                    t('Fotos', 'Photos'),
                    style: _inter.copyWith(color: Colors.white),
                  ),
                  onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.camera_alt_outlined,
                    color: Colors.white,
                  ),
                  title: Text(
                    t('Kamera', 'Camera'),
                    style: _inter.copyWith(color: Colors.white),
                  ),
                  onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatPhotoDate(String? iso) {
    final parsed = parseUtcTimestamp(iso);
    if (parsed == null) return '';
    final d = parsed.toLocal();
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd.$mm.${d.year}';
  }

  void _showAvatarPreview(String? avatarUrl, String username) {
    final trimmedUrl = avatarUrl?.trim() ?? '';
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) {
        final side = MediaQuery.of(ctx).size.width * 0.72;
        return GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: SafeArea(
            child: Center(
              child: Container(
                width: side,
                height: side,
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF1E1E1E),
                ),
                child: trimmedUrl.isNotEmpty
                    ? sideQuestNetworkImage(
                        imageUrl: trimmedUrl,
                        fit: BoxFit.cover,
                        cacheWidth: sideQuestCacheWidth(ctx, side),
                        cacheHeight: sideQuestCacheWidth(ctx, side),
                        filterQuality: FilterQuality.low,
                        errorWidget: Center(
                          child: Text(
                            username.isNotEmpty
                                ? username[0].toUpperCase()
                                : 'U',
                            style: _inter.copyWith(
                              color: Colors.white,
                              fontSize: 64,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      )
                    : Center(
                        child: Text(
                          username.isNotEmpty ? username[0].toUpperCase() : 'U',
                          style: _inter.copyWith(
                            color: Colors.white,
                            fontSize: 64,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showPhotoPreview({
    required String imageUrl,
    String? createdAt,
    String? challengeTitle,
    String? challengeDescription,
  }) {
    final dateLabel = _formatPhotoDate(createdAt);
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        final dialogWidth = size.width - 32;
        final imageHeight = (dialogWidth * 16 / 9)
            .clamp(0.0, size.height * 0.62)
            .toDouble();

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height * 0.9),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF141414),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFF2A2A2A)),
              ),
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: SizedBox(
                        height: imageHeight,
                        child: AspectRatio(
                          aspectRatio: 9 / 16,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: sideQuestNetworkImage(
                              imageUrl: imageUrl,
                              fit: BoxFit.cover,
                              cacheWidth: sideQuestCacheWidth(
                                context,
                                imageHeight * (9 / 16),
                              ),
                              cacheHeight: sideQuestCacheWidth(
                                context,
                                imageHeight,
                              ),
                              errorWidget: const ColoredBox(
                                color: Color(0xFF0C0C0C),
                                child: Center(
                                  child: Icon(
                                    Icons.broken_image_outlined,
                                    color: Colors.white54,
                                    size: 36,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if ((challengeTitle ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        challengeTitle!.trim(),
                        style: _inter.copyWith(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    if ((challengeDescription ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        challengeDescription!.trim(),
                        style: _inter.copyWith(
                          color: const Color(0xFFB8B8B8),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    if (dateLabel.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Center(
                        child: Text(
                          dateLabel,
                          style: _inter.copyWith(
                            color: const Color(0xFFB8B8B8),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLimitedProfileView({
    required Color accentGreen,
    required String username,
    required String? avatarUrl,
    required bool friendRequestPending,
    required bool friendRequestIncoming,
    required bool isBlocked,
    required bool blockedByMe,
    required VoidCallback onAddFriend,
    List<Map<String, dynamic>> mutualFriends = const [],
  }) {
    final trimmedUrl = avatarUrl?.trim() ?? '';
    final blockedActionLabel = blockedByMe
        ? t('Blockiert', 'Blocked')
        : t('Nicht verfügbar', 'Unavailable');
    final actionLabel = friendRequestIncoming
        ? t('Anfrage offen', 'Request pending')
        : friendRequestPending
        ? t('Anfrage gesendet', 'Request sent')
        : t('Freund hinzufügen', 'Add friend');
    final canSend =
        !isBlocked && !friendRequestPending && !friendRequestIncoming;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 20),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.maybePop(context),
                  icon: Icon(Icons.arrow_back, color: accentGreen),
                ),
              ],
            ),
            const Spacer(),
            GestureDetector(
              onTap: () => _showAvatarPreview(avatarUrl, username),
              child: Container(
                width: 208,
                height: 208,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: accentGreen, width: 2),
                ),
                child: ClipOval(
                  child: trimmedUrl.isNotEmpty
                      ? sideQuestNetworkImage(
                          imageUrl: trimmedUrl,
                          fit: BoxFit.cover,
                          cacheWidth: sideQuestCacheWidth(context, 208),
                          cacheHeight: sideQuestCacheWidth(context, 208),
                          filterQuality: FilterQuality.low,
                          errorWidget: Container(
                            color: const Color(0xFF1E1E1E),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.person,
                              color: Colors.white70,
                              size: 86,
                            ),
                          ),
                        )
                      : Container(
                          color: const Color(0xFF1E1E1E),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.person,
                            color: Colors.white70,
                            size: 86,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              username,
              textAlign: TextAlign.center,
              style: _inter.copyWith(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (mutualFriends.isNotEmpty) ...[
              const SizedBox(height: 8),
              _MutualFriendsHint(mutuals: mutualFriends),
            ],
            const SizedBox(height: 12),
            if (isBlocked) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  blockedByMe
                      ? t(
                          'Du hast diesen Nutzer blockiert. In den Einstellungen kannst du ihn wieder entblocken.',
                          'You blocked this user. You can unblock them in settings.',
                        )
                      : t(
                          'Dieser Nutzer ist derzeit nicht verfügbar.',
                          'This user is currently unavailable.',
                        ),
                  textAlign: TextAlign.center,
                  style: _inter.copyWith(
                    color: const Color(0xFFB8B8B8),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            SizedBox(
              width: 240,
              child: ElevatedButton.icon(
                onPressed: canSend && !_sendingFriendRequest
                    ? onAddFriend
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentGreen,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: const Color(0xFF2A2A2A),
                  disabledForegroundColor: Colors.white70,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: _sendingFriendRequest
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: canSend ? Colors.black : Colors.white70,
                        ),
                      )
                    : Icon(
                        isBlocked
                            ? Icons.block
                            : friendRequestPending || friendRequestIncoming
                            ? Icons.check_circle_outline
                            : Icons.person_add_alt_1_rounded,
                        size: 18,
                      ),
                label: Text(
                  _sendingFriendRequest
                      ? t('Senden...', 'Sending...')
                      : (isBlocked ? blockedActionLabel : actionLabel),
                  style: _inter.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            if (friendRequestIncoming && !isBlocked) ...[
              const SizedBox(height: 8),
              Text(
                t(
                  'Öffne den Freunde-Tab, um die Anfrage anzunehmen.',
                  'Open the Friends tab to accept the request.',
                ),
                textAlign: TextAlign.center,
                style: _inter.copyWith(
                  color: const Color(0xFFB8B8B8),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const Spacer(),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Neutral dark grey to match the rest of the app (feed, leaderboard,
    // friends). The login screen keeps its branded green tint, but tabs
    // share this surface.
    const darkBg = Color(0xFF121212);
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final accentGreen = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: darkBg,
      body: FutureBuilder<Map<String, dynamic>>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  t(
                    'Profil konnte nicht geladen werden.',
                    'Could not load profile.',
                  ),
                  textAlign: TextAlign.center,
                  style: _inter.copyWith(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
          }

          if (!snapshot.hasData) {
            return Center(
              key: ValueKey('profile_loading'),
              child: CircularProgressIndicator(color: accentGreen),
            );
          }

          final profile = snapshot.data!;
          final username = (profile['username'] as String?) ?? 'Unknown';
          final avatarUrl = profile['profile_picture'] as String?;
          final ownPhotos = ((profile['own_photos'] as List?) ?? const [])
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList(growable: false);
          final streakFlames = (profile['flames'] as num?)?.toInt() ?? 0;
          final postCount = (profile['all_photo_count'] as num?)?.toInt() ?? 0;
          final jokerCount = (profile['joker'] as num?)?.toInt() ?? 0;
          final pvpWinRate = (profile['pvp_win_rate'] as num?)?.toInt() ?? -1;
          final pvpWinRateLabel = pvpWinRate >= 0 ? '$pvpWinRate%' : '-';
          final currentUserId = Supabase.instance.client.auth.currentUser?.id;
          final viewedUserId = profile['id']?.toString();
          final isOwnProfile =
              currentUserId != null && currentUserId == viewedUserId;
          final isLimitedView = profile['limited_view'] == true;
          final friendshipStatus = (profile['friendship_status'] ?? '')
              .toString();
          final isBlocked = profile['is_blocked'] == true;
          final blockedByMe = profile['blocked_by_me'] == true;

          if (isLimitedView) {
            final hasPending =
                _friendRequestJustSent || friendshipStatus == 'pending';
            final isIncomingPending =
                profile['friend_request_incoming'] == true;
            return _buildLimitedProfileView(
              accentGreen: accentGreen,
              username: username,
              avatarUrl: avatarUrl,
              friendRequestPending: hasPending,
              friendRequestIncoming: isIncomingPending,
              isBlocked: isBlocked,
              blockedByMe: blockedByMe,
              onAddFriend: () =>
                  _sendFriendRequestFromProfile(viewedUserId ?? ''),
              mutualFriends:
                  (profile['mutual_friends'] as List?)
                      ?.whereType<Map<String, dynamic>>()
                      .toList(growable: false) ??
                  const [],
            );
          }

          final headerScale = sideQuestResponsiveScale(
            context,
            minScale: 0.78,
            maxScale: 1.0,
          );

          return Stack(
            children: [
              // Solid neutral grey, no green tint.
              const Positioned.fill(
                child: ColoredBox(color: darkBg),
              ),
              SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 140),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          if (!isOwnProfile)
                            IconButton(
                              onPressed: () => Navigator.maybePop(context),
                              icon: Icon(Icons.arrow_back, color: accentGreen),
                            ),
                          Expanded(
                            child: ShaderMask(
                              shaderCallback: (bounds) => LinearGradient(
                                colors: [Colors.white, accentGreen],
                              ).createShader(bounds),
                              child: Text(
                                t('Profil', 'Profile'),
                                style: _inter.copyWith(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                  letterSpacing: -0.3,
                                ),
                              ),
                            ),
                          ),
                          if (isOwnProfile)
                            NotificationInboxButton(iconColor: accentGreen),
                          if (isOwnProfile)
                            IconButton(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const AppSettingsScreen(),
                                  ),
                                );
                              },
                              icon: Icon(Icons.settings, color: accentGreen),
                            ),
                          if (!isOwnProfile && friendshipStatus == 'accepted')
                            PopupMenuButton<String>(
                              color: cardDark,
                              tooltip: t('Optionen', 'Options'),
                              icon: Icon(Icons.more_vert, color: accentGreen),
                              onSelected: (value) async {
                                if (value == 'remove_friend' &&
                                    viewedUserId != null) {
                                  await _removeFriendFromProfile(viewedUserId);
                                } else if (value == 'block' &&
                                    viewedUserId != null) {
                                  await _blockUserFromProfile(viewedUserId);
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem<String>(
                                  value: 'remove_friend',
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.delete_outline,
                                        color: Color(0xFFFFB74D),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        t('Freund entfernen', 'Remove friend'),
                                        style: _inter.copyWith(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuItem<String>(
                                  value: 'block',
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.block,
                                        color: Colors.redAccent,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        t('Blockieren', 'Block'),
                                        style: _inter.copyWith(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      LayoutBuilder(
                        builder: (context, headerConstraints) {
                          final statWidgets = <Widget>[
                            ProfileStatChip(
                              value: postCount.toString(),
                              label: t('Beiträge', 'Posts'),
                              accent: appGreen,
                              active: postCount > 0,
                              icon: Icons.photo_library_rounded,
                            ),
                            ProfileStatChip(
                              value: streakFlames.toString(),
                              label: 'Streak',
                              accent: const Color(0xFFFF8A00),
                              active: streakFlames > 0,
                              icon: Icons.local_fire_department_rounded,
                            ),
                            ProfileStatChip(
                              value: jokerCount.toString(),
                              label: 'Joker',
                              accent: const Color(0xFFFFC14D),
                              active: jokerCount > 0,
                              icon: Icons.star_rounded,
                            ),
                            ProfileStatChip(
                              value: pvpWinRate >= 0
                                  ? pvpWinRateLabel
                                  : '–',
                              label: t('Duelle', 'Duels'),
                              accent: const Color(0xFFB39DFF),
                              active: pvpWinRate >= 0,
                              icon: Icons.emoji_events_rounded,
                            ),
                          ];
                          final spacing = sideQuestResponsiveSize(
                            context,
                            10,
                            minScale: 0.72,
                            maxScale: 1.0,
                          );
                          Widget buildStatsBlock(double availableWidth) {
                            // Threshold lowered from 360 → 280: on regular
                            // iPhones the 4 stat tiles should stay in a single
                            // row. Only the smallest phones (iPhone SE 1st gen)
                            // fall back to the 2x2 grid.
                            if (availableWidth < 280) {
                              final itemWidth = math.max(
                                0.0,
                                (availableWidth - spacing) / 2,
                              );
                              return Wrap(
                                alignment: WrapAlignment.center,
                                spacing: spacing,
                                runSpacing: spacing,
                                children: statWidgets
                                    .map(
                                      (widget) => SizedBox(
                                        width: itemWidth,
                                        child: widget,
                                      ),
                                    )
                                    .toList(),
                              );
                            }

                            // Stats now live in their own pills, so just
                            // space them out evenly.
                            final children = <Widget>[];
                            for (var i = 0; i < statWidgets.length; i++) {
                              children.add(Expanded(child: statWidgets[i]));
                              if (i != statWidgets.length - 1) {
                                children.add(SizedBox(width: spacing));
                              }
                            }
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: children,
                            );
                          }

                          final avatarWidget = GestureDetector(
                            onTap: () =>
                                _showAvatarPreview(avatarUrl, username),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(2.5),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: accentGreen,
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF121212),
                                      shape: BoxShape.circle,
                                    ),
                                    child: CircleAvatar(
                                      radius: 52 * headerScale,
                                      backgroundColor: const Color(
                                        0xFF1A1A1A,
                                      ),
                                      backgroundImage: avatarUrl != null
                                          ? sideQuestCachedImageProvider(
                                              avatarUrl,
                                              cacheWidth: sideQuestCacheWidth(
                                                context,
                                                104,
                                              ),
                                              cacheHeight:
                                                  sideQuestCacheWidth(
                                                    context,
                                                    104,
                                                  ),
                                            )
                                          : null,
                                      child: avatarUrl == null
                                          ? Text(
                                              username.isNotEmpty
                                                  ? username[0].toUpperCase()
                                                  : 'U',
                                              style: _inter.copyWith(
                                                color: Colors.white,
                                                fontSize: 40 * headerScale,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            )
                                          : null,
                                    ),
                                  ),
                                ),
                                if (isOwnProfile)
                                  Positioned(
                                    right: -2,
                                    bottom: -2,
                                    child: GestureDetector(
                                      onTap: updateProfilePicture,
                                      child: Container(
                                        width: 34 * headerScale,
                                        height: 34 * headerScale,
                                        decoration: BoxDecoration(
                                          color: accentGreen,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: const Color(0xFF121212),
                                            width: 2.5,
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.add,
                                          color: Colors.white,
                                          size: 18 * headerScale,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );

                          // Identity row: avatar + name (right of avatar).
                          // Stats live in a separate row below so the name
                          // sits right next to the face — feels more like
                          // a real social-app profile and less stretched out.
                          final identityRow = Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              avatarWidget,
                              SizedBox(width: 16 * headerScale),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      username,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _inter.copyWith(
                                        color: textPrimary,
                                        fontSize: sideQuestResponsiveSize(
                                          context,
                                          30,
                                          minScale: 0.82,
                                          maxScale: 1.0,
                                        ),
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.3,
                                        height: 1.05,
                                      ),
                                    ),
                                    SizedBox(height: 4 * headerScale),
                                    Text(
                                      '@${username.toLowerCase()}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _inter.copyWith(
                                        color: const Color(0xFFB39DFF),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.1,
                                      ),
                                    ),
                                    if (!isOwnProfile)
                                      _MutualFriendsHint(
                                        mutuals:
                                            (profile['mutual_friends']
                                                    as List?)
                                                ?.whereType<
                                                  Map<String, dynamic>
                                                >()
                                                .toList(growable: false) ??
                                            const [],
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          );

                          final crowdFavoriteCount =
                              (profile['crowd_favorite_count'] as num?)
                                  ?.toInt() ??
                              0;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              identityRow,
                              SizedBox(height: 18 * headerScale),
                              buildStatsBlock(headerConstraints.maxWidth),
                              if (crowdFavoriteCount > 0) ...[
                                const SizedBox(height: 12),
                                Center(
                                  child: CrowdFavoriteBadge(
                                    count: crowdFavoriteCount,
                                    active: crowdFavoriteActive(
                                      profile['crowd_favorite_active_until'],
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 22),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          ShaderMask(
                            shaderCallback: (bounds) => LinearGradient(
                              colors: [Colors.white, accentGreen],
                            ).createShader(bounds),
                            child: Text(
                              t('Galerie', 'Gallery'),
                              style: _inter.copyWith(
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          Text(
                            ownPhotos.length.toString(),
                            style: _inter.copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: textSecondary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (ownPhotos.isEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 32,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.03),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.07),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              isOwnProfile
                                  ? t(
                                      'Du hast noch keine Fotos gepostet.',
                                      'You have not posted any photos yet.',
                                    )
                                  : t(
                                      'Dieser Benutzer hat noch keine Fotos gepostet.',
                                      'This user has not posted any photos yet.',
                                    ),
                              textAlign: TextAlign.center,
                              style: _inter.copyWith(
                                fontSize: 15,
                                color: textSecondary,
                              ),
                            ),
                          ),
                        )
                      else
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: ownPhotos.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                mainAxisSpacing: 8,
                                crossAxisSpacing: 8,
                                childAspectRatio: 1,
                              ),
                          itemBuilder: (context, index) {
                            final photo = ownPhotos[index];
                            final url = (photo['url'] ?? '').toString();
                            final photoId = (photo['id'] ?? '').toString();
                            final createdAt = photo['created_at']?.toString();
                            final challengeTitle = (photo['daily_title'] ?? '')
                                .toString();
                            final challengeDescription =
                                (photo['daily_description'] ?? '').toString();

                            return GestureDetector(
                              onTap: () => _showPhotoPreview(
                                imageUrl: url,
                                createdAt: createdAt,
                                challengeTitle: challengeTitle,
                                challengeDescription: challengeDescription,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    sideQuestNetworkImage(
                                      imageUrl: listImageUrl(photo),
                                      fit: BoxFit.cover,
                                      cacheWidth: sideQuestCacheWidth(
                                        context,
                                        MediaQuery.of(context).size.width / 3,
                                      ),
                                      cacheHeight: sideQuestCacheWidth(
                                        context,
                                        MediaQuery.of(context).size.width / 3,
                                      ),
                                      filterQuality: FilterQuality.low,
                                      errorWidget: Container(
                                        color: const Color(0xFF1A1A1A),
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          Icons.broken_image_outlined,
                                          color: Colors.white54,
                                          size: 24,
                                        ),
                                      ),
                                    ),
                                    if (challengeTitle.trim().isNotEmpty)
                                      Positioned(
                                        left: 0,
                                        right: 0,
                                        bottom: 0,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 4,
                                          ),
                                          color: Colors.black.withValues(
                                            alpha: 0.5,
                                          ),
                                          child: Text(
                                            challengeTitle,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: _inter.copyWith(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                    // The post menu (save / delete) is only
                                    // available on your OWN profile — you can
                                    // never save someone else's photos, not
                                    // even a friend's.
                                    if (isOwnProfile)
                                      Positioned(
                                        top: 4,
                                        right: 4,
                                        child: _PostCardMenu(
                                          onSave: () =>
                                              _savePhotoToDevice(url),
                                          onDelete: () =>
                                              _confirmDeleteOwnPhoto(photoId),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      if (ownPhotos.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          t(
                            'Tippe ein Foto an für die komplette Daily-Quest-Beschreibung.',
                            'Tap a photo to view the full Daily Quest description.',
                          ),
                          style: _inter.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The "⋯" overflow button shown in the top-right corner of post cards on
/// your OWN profile. Lets you save the photo to your device or delete the
/// post. It is never rendered on another user's profile, so there is no way
/// to save someone else's photos — friends included.
class _PostCardMenu extends StatelessWidget {
  final VoidCallback onSave;
  final VoidCallback onDelete;

  const _PostCardMenu({
    required this.onSave,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      color: const Color(0xFF1E1E1E),
      padding: EdgeInsets.zero,
      tooltip: t('Optionen', 'Options'),
      // Using `child` (not `icon`) so the tap target isn't padded out to the
      // 48px minimum that PopupMenuButton's internal IconButton enforces.
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.more_horiz,
          color: Colors.white,
          size: 16,
        ),
      ),
      onSelected: (value) {
        if (value == 'save') {
          onSave();
        } else if (value == 'delete') {
          onDelete();
        }
      },
        itemBuilder: (ctx) => [
          PopupMenuItem<String>(
            value: 'save',
            child: Row(
              children: [
                const Icon(
                  Icons.download_rounded,
                  size: 18,
                  color: Colors.white,
                ),
                const SizedBox(width: 10),
                Text(
                  t('In Fotos speichern', 'Save to Photos'),
                  style: _inter.copyWith(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'delete',
            child: Row(
              children: [
                const Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: Colors.redAccent,
                ),
                const SizedBox(width: 10),
                Text(
                  t('Löschen', 'Delete'),
                  style: _inter.copyWith(
                    color: Colors.redAccent,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
    );
  }
}

/// Instagram-style "X, Y und N weitere sind befreundet" hint shown on a
/// foreign profile. Renders nothing when there are no mutual friends.
class _MutualFriendsHint extends StatelessWidget {
  final List<Map<String, dynamic>> mutuals;

  const _MutualFriendsHint({required this.mutuals});

  @override
  Widget build(BuildContext context) {
    if (mutuals.isEmpty) return const SizedBox.shrink();

    const avatarSize = 18.0;
    const overlap = 6.0;
    final previewCount = mutuals.length >= 2 ? 2 : 1;
    final remainder = mutuals.length - previewCount;
    final stackWidth =
        avatarSize + (previewCount - 1) * (avatarSize - overlap);

    final nameSpans = <InlineSpan>[];
    for (var i = 0; i < previewCount; i++) {
      nameSpans.add(
        TextSpan(
          text: (mutuals[i]['username'] ?? '').toString(),
          style: GoogleFonts.inter(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      if (i == 0 && previewCount > 1) {
        nameSpans.add(
          TextSpan(
            text: ', ',
            style: GoogleFonts.inter(
              color: const Color(0xFFB0B0B0),
              fontSize: 12,
            ),
          ),
        );
      }
    }

    final String trailing = remainder > 0
        ? t(
            ' und $remainder weitere sind befreundet',
            ' and $remainder others are friends',
          )
        : t(' ist befreundet', ' is a friend');

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: stackWidth,
            height: avatarSize,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = 0; i < previewCount; i++)
                  Positioned(
                    left: i * (avatarSize - overlap),
                    child: _MutualAvatar(
                      profile: mutuals[i],
                      size: avatarSize,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  ...nameSpans,
                  TextSpan(
                    text: trailing,
                    style: GoogleFonts.inter(
                      color: const Color(0xFFB0B0B0),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _MutualAvatar extends StatelessWidget {
  final Map<String, dynamic> profile;
  final double size;

  const _MutualAvatar({required this.profile, required this.size});

  @override
  Widget build(BuildContext context) {
    final pic = (profile['profile_picture'] ?? '').toString().trim();
    final username = (profile['username'] ?? '').toString();
    final cacheSize = sideQuestCacheWidth(context, size);
    final provider = pic.isEmpty
        ? null
        : sideQuestCachedImageProvider(
            pic,
            cacheWidth: cacheSize,
            cacheHeight: cacheSize,
          );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: const Color(0xFF121212), width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: provider != null
          ? Image(image: provider, fit: BoxFit.cover)
          : Center(
              child: Text(
                username.isNotEmpty ? username[0].toUpperCase() : '?',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
    );
  }
}
