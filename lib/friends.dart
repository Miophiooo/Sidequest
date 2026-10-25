import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'analytics_service.dart';
import 'block_service.dart';
import 'core/app_logger.dart';
import 'core/error_mapper.dart';
import 'features/chat/message_status.dart';
import 'features/duels/duel_results.dart';
import 'features/invite/add_friend_actions.dart';
import 'features/invite/invite_progress_card.dart';
import 'features/invite/invite_share.dart';
import 'friend_discovery.dart';
import 'image_compression.dart';
import 'image_validation.dart';
import 'message_report_service.dart';
import 'shared.dart';
import 'widgets/lightning_strike_overlay.dart';
import 'profile.dart';
import 'daily_challenges.dart';

/// Cached Inter TextStyle – avoids repeated font-family lookups in build().
final TextStyle _inter = GoogleFonts.inter(fontWeight: FontWeight.w700);

/// Duel invites expire after this long; the server refuses later accepts.
const Duration kDuelInviteLifetime = Duration(hours: 2);

DateTime? _duelInviteExpiresAt(Map<String, dynamic> challenge) {
  // server_created_at is set by the server; created_at is only a fallback
  // for rows from older builds.
  final createdAt =
      parseUtcTimestamp(challenge['server_created_at']) ??
      parseUtcTimestamp(challenge['created_at']);
  return createdAt?.add(kDuelInviteLifetime);
}

bool isDuelInviteExpired(Map<String, dynamic> challenge, DateTime nowUtc) {
  final expiresAt = _duelInviteExpiresAt(challenge);
  return expiresAt != null && !nowUtc.isBefore(expiresAt);
}

String duelInviteTimeLeftLabel(Map<String, dynamic> challenge) {
  final expiresAt = _duelInviteExpiresAt(challenge);
  if (expiresAt == null) return '';
  final left = expiresAt.difference(DateTime.now().toUtc());
  if (left.isNegative) return t('Abgelaufen', 'Expired');
  final hours = left.inHours;
  final minutes = left.inMinutes % 60;
  final text = hours > 0
      ? '$hours h $minutes min'
      : minutes > 0
      ? '$minutes min'
      : '< 1 min';
  return t('⏳ Noch $text zum Annehmen', '⏳ $text left to accept');
}

/// Pending invites created before this instant are expired: either from an
/// earlier challenge day or older than [kDuelInviteLifetime].
DateTime _pendingInviteCutoff(DateTime activeDailyStartLocal) {
  final lifetimeCutoff = DateTime.now().subtract(kDuelInviteLifetime);
  return lifetimeCutoff.isAfter(activeDailyStartLocal)
      ? lifetimeCutoff
      : activeDailyStartLocal;
}

class FriendsScreen extends StatefulWidget {
  final VoidCallback? onUnreadCountChanged;

  const FriendsScreen({super.key, this.onUnreadCountChanged});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen>
    with SingleTickerProviderStateMixin {
  final usernameCtrl = TextEditingController();
  final FocusNode _usernameFocusNode = FocusNode();
  bool loading = false;
  Map<String, bool> challengeLoadingStates = {};
  final picker = ImagePicker();
  Map<String, bool> uploadingStates = {};
  Map<String, bool> sabotageLoadingStates = {};
  String? _animatingBoltFriendId;
  final Set<String> _handledExpiredInviteIds = <String>{};
  final Set<String> _expiringChallengeIds = <String>{};
  final Set<String> _acceptingChallengeIds = <String>{};
  late final AnimationController _boltPulseController;
  // Layer-based fades for the bolt flash glow/streak (see
  // _buildChallengeBoltIcon): same values as 0.28 + 0.34 * flash and
  // 0.22 + 0.52 * flash, without repainting the glow every frame.
  late final Animation<double> _boltGlowOpacity;
  late final Animation<double> _boltStreakOpacity;
  Future<List<Map<String, dynamic>>>? _friendsFuture;
  Future<List<Map<String, dynamic>>>? _incomingChallengesFuture;
  List<DuelResult> _duelResults = const [];

  Timer? _usernameSuggestDebounce;
  bool _usernameSuggestLoading = false;
  List<Map<String, dynamic>> _usernameSuggestions = [];

  RealtimeChannel? _friendsChallengesSubscription;
  RealtimeChannel? _friendsMessagesSubscription;
  RealtimeChannel? _friendsRelationSubscription;
  Timer? _friendsRefreshDebounce;
  DateTime? _lastPendingChallengeCleanupAt;

  @override
  void initState() {
    super.initState();
    _boltPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    );
    // flash = raw < 0.28 ? 1 - easeOut(raw / 0.28) : 0
    final boltFlash = Tween<double>(begin: 1.0, end: 0.0).chain(
      CurveTween(curve: const Interval(0.0, 0.28, curve: Curves.easeOut)),
    );
    _boltGlowOpacity = _boltPulseController.drive(
      Tween<double>(begin: 0.28, end: 0.62).chain(boltFlash),
    );
    _boltStreakOpacity = _boltPulseController.drive(
      Tween<double>(begin: 0.22, end: 0.74).chain(boltFlash),
    );
    _incomingChallengesFuture = loadIncomingChallenges();
    _friendsFuture = loadFriends();
    unawaited(_loadDuelResults());
    usernameCtrl.addListener(_onUsernameChanged);
    _setupFriendsChallengeRealtime();
    _setupFriendsMessagesRealtime();
    _setupFriendsRelationRealtime();
    _usernameFocusNode.addListener(() {
      if (!_usernameFocusNode.hasFocus && mounted) {
        setState(() {
          _usernameSuggestions = [];
          _usernameSuggestLoading = false;
        });
      }
    });
  }

  void _setupFriendsChallengeRealtime() {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    _friendsChallengesSubscription?.unsubscribe();
    _friendsChallengesSubscription = client
        .channel('friends_challenges_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'challenges',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'challenger_id',
            value: userId,
          ),
          callback: (_) => _scheduleFriendsRefresh(duelResults: true),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'challenges',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'challenged_id',
            value: userId,
          ),
          callback: (_) => _scheduleFriendsRefresh(duelResults: true),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'challenges',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'challenger_id',
            value: userId,
          ),
          callback: (_) => _scheduleFriendsRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'challenges',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'challenged_id',
            value: userId,
          ),
          callback: (_) => _scheduleFriendsRefresh(),
        )
        .subscribe();
  }

  void _setupFriendsMessagesRealtime() {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    void refreshBadges() {
      _scheduleFriendsRefresh();
      widget.onUnreadCountChanged?.call();
    }

    _friendsMessagesSubscription?.unsubscribe();
    _friendsMessagesSubscription = client
        .channel('friends_messages_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_id',
            value: userId,
          ),
          callback: (_) => refreshBadges(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: userId,
          ),
          callback: (_) => refreshBadges(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_id',
            value: userId,
          ),
          callback: (_) => refreshBadges(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: userId,
          ),
          callback: (_) => refreshBadges(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'receiver_id',
            value: userId,
          ),
          callback: (_) => refreshBadges(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: userId,
          ),
          callback: (_) => refreshBadges(),
        )
        .subscribe();
  }

  /// Listens for changes on the `friends` table so that newly sent, received,
  /// accepted, or declined friend requests show up immediately — without
  /// needing the user to close and reopen the app.
  ///
  /// Subscribes to both `user_id` and `friend_id` sides because either column
  /// can reference the current user depending on who initiated the request.
  void _setupFriendsRelationRealtime() {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    _friendsRelationSubscription?.unsubscribe();
    _friendsRelationSubscription = client
        .channel('friends_relation_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleFriendsRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'friend_id',
            value: userId,
          ),
          callback: (_) => _scheduleFriendsRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleFriendsRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'friend_id',
            value: userId,
          ),
          callback: (_) => _scheduleFriendsRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleFriendsRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'friends',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'friend_id',
            value: userId,
          ),
          callback: (_) => _scheduleFriendsRefresh(),
        )
        .subscribe();
  }

  bool _refreshDuelResultsPending = false;

  void _scheduleFriendsRefresh({bool duelResults = false}) {
    if (duelResults) _refreshDuelResultsPending = true;
    _friendsRefreshDebounce?.cancel();
    _friendsRefreshDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _incomingChallengesFuture = loadIncomingChallenges();
        _friendsFuture = loadFriends();
      });
      if (_refreshDuelResultsPending) {
        _refreshDuelResultsPending = false;
        unawaited(_loadDuelResults());
      }
    });
  }

  Future<void> _loadDuelResults() async {
    final results = await DuelResults.loadUnseen();
    if (!mounted) return;
    setState(() => _duelResults = results);
  }

  void _closeDuelResult(DuelResult result) {
    setState(() {
      _duelResults = _duelResults
          .where((r) => r.challengeId != result.challengeId)
          .toList(growable: false);
    });
    unawaited(DuelResults.markSeen(result.challengeId));
  }

  Widget _buildDuelResults() {
    if (_duelResults.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: _duelResults.every((r) => r.outcome == DuelOutcome.expired)
          ? 118
          : 210,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        itemCount: _duelResults.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final result = _duelResults[index];
          return Align(
            alignment: Alignment.topCenter,
            child: DuelResultCard(
              result: result,
              onClose: () => _closeDuelResult(result),
              onRematch: () {
                _closeDuelResult(result);
                unawaited(sendChallenge(result.opponentId, result.opponentName));
              },
            ),
          );
        },
      ),
    );
  }

  DateTime _activeDailyStartLocal([DateTime? nowLocal]) {
    final now = nowLocal ?? DateTime.now();
    DateTime activeStart = challengeStartLocal(now);
    if (now.isBefore(activeStart)) {
      activeStart = challengeStartLocal(now.subtract(const Duration(days: 1)));
    }
    return activeStart;
  }

  Future<void> _cleanupExpiredPendingChallenges({bool force = false}) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    final now = DateTime.now();
    if (!force &&
        _lastPendingChallengeCleanupAt != null &&
        now.difference(_lastPendingChallengeCleanupAt!) <
            const Duration(minutes: 1)) {
      return;
    }
    _lastPendingChallengeCleanupAt = now;

    final cutoffIso = _pendingInviteCutoff(
      _activeDailyStartLocal(now),
    ).toUtc().toIso8601String();

    try {
      final expiredPending = await client
          .from("challenges")
          .select("id")
          .or("challenger_id.eq.$userId,challenged_id.eq.$userId")
          .eq("status", "pending")
          .lt("created_at", cutoffIso);

      if (expiredPending.isEmpty) return;

      final ids = expiredPending
          .map((c) => (c['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();
      if (ids.isEmpty) return;

      // RLS has no delete policy for challenges (a blocked delete silently
      // removes nothing), so expired invites are marked declined instead.
      await client
          .from("challenges")
          .update({"status": "declined"})
          .inFilter("id", ids);
    } catch (e) {
      AppLogger.debug("Error cleaning up expired pending challenges: $e");
    }
  }

  DateTime? _effectiveChallengeExpiryForCurrentUser(
    Map<String, dynamic> challenge,
    String userId,
  ) {
    final challengerId = (challenge['challenger_id'] ?? '').toString();
    final fallbackExpires = challenge['expires_at'];
    final rawExpires = challengerId == userId
        ? (challenge['challenger_expires_at'] ?? fallbackExpires)
        : (challenge['challenged_expires_at'] ?? fallbackExpires);
    final expiresAtStr = rawExpires?.toString().trim() ?? '';
    if (expiresAtStr.isEmpty) return null;
    return DateTime.tryParse(expiresAtStr);
  }

  int _dailyPvpChallengeRank(String dayKey, Map<String, dynamic> challenge) {
    final challengeKey = [
      (challenge['id'] ?? '').toString(),
      (challenge['scope'] ?? '').toString(),
      (challenge['de'] ?? '').toString(),
      (challenge['en'] ?? '').toString(),
    ].join('|');

    var hash = 2166136261;
    for (final codeUnit in '$dayKey|$challengeKey'.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return hash;
  }

  List<Map<String, dynamic>> _dailyPvpChallengeSelection(
    List<Map<String, dynamic>> challenges, {
    int maxCount = 6,
  }) {
    if (challenges.length <= maxCount) {
      return List<Map<String, dynamic>>.from(challenges, growable: false);
    }

    final dayKey = DateTime.now().toUtc().toIso8601String().split('T').first;
    final ranked = List<Map<String, dynamic>>.from(challenges)
      ..sort((a, b) {
        final rankCompare = _dailyPvpChallengeRank(
          dayKey,
          a,
        ).compareTo(_dailyPvpChallengeRank(dayKey, b));
        if (rankCompare != 0) return rankCompare;
        return (a['id'] ?? '').toString().compareTo((b['id'] ?? '').toString());
      });

    return ranked.take(maxCount).toList(growable: false);
  }

  String _composeChallengeDescription(Map<String, dynamic> challenge) {
    return t(
      (challenge['de'] ?? '').toString(),
      (challenge['en'] ?? '').toString(),
    ).trim();
  }

  Future<void> _failExpiredChallengeIfNobodyPosted({
    required String challengeId,
    required String partnerId,
  }) async {
    if (challengeId.isEmpty || partnerId.isEmpty) return;
    if (_expiringChallengeIds.contains(challengeId)) return;

    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    _expiringChallengeIds.add(challengeId);
    try {
      final rawChallenge = await client
          .from('challenges')
          .select(
            'id, status, completed_at, winner_id, challenger_id, challenged_id, expires_at, challenger_expires_at, challenged_expires_at',
          )
          .eq('id', challengeId)
          .maybeSingle();
      if (rawChallenge == null) return;

      final challenge = Map<String, dynamic>.from(rawChallenge);
      final status = (challenge['status'] ?? '').toString();
      if (status != 'accepted' ||
          challenge['completed_at'] != null ||
          challenge['winner_id'] != null) {
        return;
      }

      final expiresAt = _effectiveChallengeExpiryForCurrentUser(
        challenge,
        userId,
      );
      if (expiresAt == null || DateTime.now().isBefore(expiresAt)) return;

      final challengerId = (challenge['challenger_id'] ?? '').toString();
      final challengedId = (challenge['challenged_id'] ?? '').toString();
      final participantIds = [
        challengerId,
        challengedId,
      ].where((id) => id.isNotEmpty).toSet().toList();
      if (participantIds.isEmpty) return;

      final existingPhotos = await client
          .from('photos')
          .select('id')
          .eq('challenge_id', challengeId)
          .inFilter('user_id', participantIds)
          .limit(1);
      if (existingPhotos.isNotEmpty) return;

      final nowIso = DateTime.now().toUtc().toIso8601String();
      final updatedChallenge = await client
          .from('challenges')
          .update({
            'status': 'failed',
            'completed_at': nowIso,
            'winner_id': null,
          })
          .eq('id', challengeId)
          .eq('status', 'accepted')
          .isFilter('completed_at', null)
          .select('id')
          .maybeSingle();
      if (updatedChallenge == null) return;

      await client.from('messages').insert({
        'sender_id': userId,
        'receiver_id': partnerId,
        'message': 'Duel failed 😥',
        'created_at': nowIso,
      });

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      AppLogger.debug('Could not fail expired challenge $challengeId: $e');
    } finally {
      _expiringChallengeIds.remove(challengeId);
    }
  }

  @override
  void dispose() {
    _boltPulseController.dispose();
    _usernameSuggestDebounce?.cancel();
    _friendsRefreshDebounce?.cancel();
    _friendsChallengesSubscription?.unsubscribe();
    _friendsMessagesSubscription?.unsubscribe();
    _friendsRelationSubscription?.unsubscribe();
    usernameCtrl.removeListener(_onUsernameChanged);
    usernameCtrl.dispose();
    _usernameFocusNode.dispose();
    super.dispose();
  }

  void _updateChallengeLoadingState(String friendId, bool value) {
    if (!mounted) {
      challengeLoadingStates[friendId] = value;
      return;
    }
    setState(() => challengeLoadingStates[friendId] = value);
    if (!value) {
      _maybeStopBoltAnimation();
    }
  }

  void _startBoltAnimation(String friendId) {
    if (_animatingBoltFriendId != friendId) {
      if (mounted) {
        setState(() => _animatingBoltFriendId = friendId);
      } else {
        _animatingBoltFriendId = friendId;
      }
    }
    if (!_boltPulseController.isAnimating) {
      _boltPulseController.repeat(reverse: true);
    }
  }

  void _finishBoltAnimation(String friendId) {
    Future.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      if (_animatingBoltFriendId == friendId) {
        setState(() => _animatingBoltFriendId = null);
      }
      _maybeStopBoltAnimation();
    });
  }

  void _maybeStopBoltAnimation() {
    if (_animatingBoltFriendId != null ||
        challengeLoadingStates.containsValue(true)) {
      return;
    }
    if (_boltPulseController.isAnimating) {
      _boltPulseController
        ..stop()
        ..value = 0;
    }
  }

  Widget _buildChallengeBoltIcon({
    required bool isActive,
    required bool isDisabled,
  }) {
    final iconColor = isDisabled ? Colors.grey : Colors.amber;
    final baseIcon = Icon(Icons.bolt_rounded, size: 22, color: iconColor);

    if (!isActive) return baseIcon;

    return AnimatedBuilder(
      animation: _boltPulseController,
      child: baseIcon,
      builder: (context, child) {
        double mix(double a, double b, double t) => a + ((b - a) * t);

        final raw = _boltPulseController.value;
        final strikePhase = (raw / 0.16).clamp(0.0, 1.0);
        final settlePhase = ((raw - 0.16) / 0.22).clamp(0.0, 1.0);
        final fadePhase = ((raw - 0.38) / 0.18).clamp(0.0, 1.0);

        final strike = Curves.easeOutExpo.transform(strikePhase);
        final settle = Curves.easeOutCubic.transform(settlePhase);
        final fade = Curves.easeIn.transform(fadePhase);
        final flicker = sin(raw * pi * 14).abs();
        final flash = raw < 0.28
            ? (1 - Curves.easeOut.transform((raw / 0.28).clamp(0.0, 1.0)))
            : 0.0;

        final scale = raw < 0.16
            ? mix(1.0, 1.28, strike)
            : raw < 0.38
            ? mix(1.28, 1.04, settle)
            : mix(1.04, 1.0, fade);
        final lift = raw < 0.16
            ? mix(0.0, -3.6, strike)
            : raw < 0.38
            ? mix(-3.6, -0.8, settle)
            : mix(-0.8, 0.0, fade);
        final tilt = raw < 0.16
            ? mix(-0.18, 0.12, strike)
            : raw < 0.38
            ? mix(0.12, -0.03, settle)
            : mix(-0.03, 0.0, fade);
        final jitterX = sin(raw * pi * 22) * (0.9 + (0.7 * flash));
        final glowAlpha = 0.18 + (0.34 * flash) + (0.08 * flicker);

        return SizedBox(
          width: 28,
          height: 28,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              FadeTransition(
                opacity: _boltGlowOpacity,
                child: Transform.scale(
                  scale: 1.1 + (0.34 * flash),
                  child: Icon(
                    Icons.bolt_rounded,
                    size: 23,
                    color: const Color(0xFFFFF0A8),
                  ),
                ),
              ),
              FadeTransition(
                opacity: _boltStreakOpacity,
                child: Transform.rotate(
                  angle: -0.68,
                  child: Container(
                    width: 22 + (10 * flash),
                    height: 2.6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.white.withValues(alpha: 0.95),
                          const Color(0xFFFFD65C).withValues(alpha: 0.95),
                          Colors.transparent,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFFFFD65C,
                          ).withValues(alpha: 0.22 + (0.22 * flash)),
                          blurRadius: 10 + (8 * flash),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(jitterX, lift),
                child: Transform.rotate(
                  angle: tilt,
                  child: Transform.scale(
                    scale: scale,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(
                            color: Colors.amber.withValues(alpha: glowAlpha),
                            blurRadius: 14 + (10 * flash),
                            spreadRadius: 0.8 + (0.9 * flash),
                          ),
                        ],
                      ),
                      child: child,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _onUsernameChanged() {
    final q = usernameCtrl.text.trim();
    _usernameSuggestDebounce?.cancel();

    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _usernameSuggestions = [];
        _usernameSuggestLoading = false;
      });
      return;
    }
    _usernameSuggestDebounce = Timer(const Duration(milliseconds: 220), () {
      _fetchUsernameSuggestions(q);
    });
  }

  Future<void> _fetchUsernameSuggestions(String query) async {
    if (!mounted) return;
    if (query.trim().isEmpty) return;

    setState(() => _usernameSuggestLoading = true);

    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) {
        setState(() {
          _usernameSuggestLoading = false;
          _usernameSuggestions = [];
        });
      }
      return;
    }

    try {
      final rows = await client
          .from('users_profile')
          .select('id, username, profile_picture')
          .ilike('username', '%$query%')
          .neq('id', userId)
          .order('username', ascending: true)
          .limit(6);

      if (!mounted) return;

      // Only apply if the user hasn't typed something else in the meantime.
      if (usernameCtrl.text.trim() != query) {
        setState(() => _usernameSuggestLoading = false);
        return;
      }

      setState(() {
        _usernameSuggestLoading = false;
        _usernameSuggestions = (rows as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .where((e) => (e['username'] ?? '').toString().trim().isNotEmpty)
            .toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _usernameSuggestLoading = false;
        _usernameSuggestions = [];
      });
    }
  }

  Widget _buildSuggestionsSection({
    required Set<String> excludeUserIds,
    bool forceVisible = false,
  }) {
    final _ = forceVisible;

    return FriendSuggestionsRail(
      placement: 'friends',
      excludeUserIds: excludeUserIds,
      onOpenProfile: (userId) {
        if (userId.isEmpty) return;
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ProfileScreen(userId: userId)),
        );
      },
      margin: const EdgeInsets.only(top: 16, bottom: 0),
    );
  }

  Future<List<Map<String, dynamic>>> loadFriends() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser!.id;

    try {
      await _cleanupExpiredPendingChallenges();
      final friendships = await client
          .from("friends")
          .select("id, user_id, friend_id, status")
          .or("user_id.eq.$userId,friend_id.eq.$userId");

      if (friendships.isEmpty) return [];

      // Build a lightweight map with the other user ids first to avoid N network calls later.
      final List<Map<String, dynamic>> baseFriends = [];
      final Set<String> otherUserIds = {};

      for (final friendship in friendships) {
        final isRequester = friendship['user_id'] == userId;
        final otherUserId = isRequester
            ? friendship['friend_id']
            : friendship['user_id'];
        otherUserIds.add(otherUserId);

        baseFriends.add({
          'otherUserId': otherUserId,
          'status': friendship['status'],
          'isRequester': isRequester,
          'friendshipId': friendship['id'],
        });
      }

      // Fetch all profiles in one request.
      final profilesResult = otherUserIds.isEmpty
          ? []
          : await client
                .from("users_profile")
                .select("id, username, profile_picture")
                .inFilter("id", otherUserIds.toList());

      final Map<String, Map<String, dynamic>> profilesById = {
        for (final profile in profilesResult) profile['id'] as String: profile,
      };

      // Fetch today's challenges involving the current user once.
      // created_at is UTC (set by the server).
      final cutoffIso = _activeDailyStartLocal().toUtc().toIso8601String();
      final todaysChallenges = await client
          .from("challenges")
          .select()
          .or("challenger_id.eq.$userId,challenged_id.eq.$userId")
          .gte("created_at", cutoffIso)
          .order("created_at", ascending: false);

      final challengeIds = todaysChallenges
          .map((c) => (c['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();
      final postedChallengeIds = <String>{};
      if (challengeIds.isNotEmpty) {
        try {
          final ownChallengePhotos = await client
              .from("photos")
              .select("challenge_id")
              .eq("user_id", userId)
              .inFilter("challenge_id", challengeIds);
          for (final row in ownChallengePhotos) {
            final cid = (row['challenge_id'] ?? '').toString();
            if (cid.isNotEmpty) postedChallengeIds.add(cid);
          }
        } catch (_) {
          // Best-effort only. If this lookup fails, keep old active behavior.
        }
      }

      final Map<String, Map<String, dynamic>> challengeStateByFriend = {};
      for (final challenge in todaysChallenges) {
        final challengerId = challenge['challenger_id'] as String;
        final challengedId = challenge['challenged_id'] as String;
        final otherId = challengerId == userId ? challengedId : challengerId;

        // Keep only the latest challenge per friend for today.
        if (challengeStateByFriend.containsKey(otherId)) continue;

        final status = (challenge['status'] ?? '').toString();
        final completedAt = challenge['completed_at'];
        final winnerId = challenge['winner_id'];

        bool hasActiveChallenge = false;
        bool hasPendingChallenge = false;
        bool hasChallengeToday = false;
        bool hasCompletedChallengeToday = false;
        Map<String, dynamic>? activeChallenge;

        if (status == 'pending' &&
            isDuelInviteExpired(
              Map<String, dynamic>.from(challenge),
              DateTime.now().toUtc(),
            )) {
          continue;
        } else if (status == 'pending') {
          hasPendingChallenge = true;
          hasChallengeToday = true;
        } else if (completedAt != null ||
            winnerId != null ||
            status == 'failed' ||
            status == 'completed') {
          hasChallengeToday = true;
          hasCompletedChallengeToday = true;
        } else if (status == 'accepted') {
          final challengeId = (challenge['id'] ?? '').toString();
          final postedOwnPhoto =
              challengeId.isNotEmpty &&
              postedChallengeIds.contains(challengeId);

          hasActiveChallenge = !postedOwnPhoto;
          hasChallengeToday = true;
          if (!postedOwnPhoto) {
            final challengerId = (challenge['challenger_id'] ?? '').toString();
            final fallbackExpires = challenge['expires_at'];
            final effectiveExpires = (challengerId == userId)
                ? (challenge['challenger_expires_at'] ?? fallbackExpires)
                : (challenge['challenged_expires_at'] ?? fallbackExpires);

            activeChallenge = {
              ...Map<String, dynamic>.from(challenge),
              'effective_expires_at': effectiveExpires,
            };
          }
        }

        challengeStateByFriend[otherId] = {
          'hasActiveChallenge': hasActiveChallenge,
          'activeChallenge': activeChallenge,
          'hasChallengeToday': hasChallengeToday,
          'hasPendingChallenge': hasPendingChallenge,
          'hasCompletedChallengeToday': hasCompletedChallengeToday,
        };
      }

      // Fetch unread messages in one query and count per sender.
      final unreadMessages = await client
          .from("messages")
          .select("sender_id")
          .eq("receiver_id", userId)
          .eq("read", false);

      final Map<String, int> unreadBySender = {};
      for (final msg in unreadMessages) {
        final sender = msg['sender_id'] as String?;
        if (sender == null) continue;
        unreadBySender[sender] = (unreadBySender[sender] ?? 0) + 1;
      }

      // Fetch latest message timestamps per friend (newest first).
      final Map<String, DateTime> lastMessageAtByFriend = {};
      if (otherUserIds.isNotEmpty) {
        final friendIds = otherUserIds.toList();
        final inList = '(${friendIds.join(',')})';
        final filter =
            'and(sender_id.eq.$userId,receiver_id.in.$inList),and(receiver_id.eq.$userId,sender_id.in.$inList)';

        final recent = await client
            .from('messages')
            .select('sender_id, receiver_id, created_at')
            .or(filter)
            .order('created_at', ascending: false)
            .limit(500);

        for (final msg in recent) {
          final sender = (msg['sender_id'] ?? '').toString();
          final receiver = (msg['receiver_id'] ?? '').toString();
          final otherId = sender == userId
              ? receiver
              : receiver == userId
              ? sender
              : null;
          if (otherId == null || otherId.isEmpty) continue;
          if (!otherUserIds.contains(otherId)) continue;
          if (lastMessageAtByFriend.containsKey(otherId)) continue;

          final createdAt = msg['created_at'];
          if (createdAt == null) continue;
          try {
            lastMessageAtByFriend[otherId] = DateTime.parse(
              createdAt.toString(),
            );
          } catch (_) {
            // Ignore unparsable timestamps.
          }
        }
      }

      final List<Map<String, dynamic>> result = [];

      for (final base in baseFriends) {
        final otherId = base['otherUserId'] as String;
        final profile = profilesById[otherId];
        if (profile == null) continue; // Skip deleted profiles.

        final challengeState =
            challengeStateByFriend[otherId] ??
            {
              'hasActiveChallenge': false,
              'activeChallenge': null,
              'hasChallengeToday': false,
              'hasPendingChallenge': false,
              'hasCompletedChallengeToday': false,
            };

        result.add({
          'id': profile['id'],
          'username': profile['username'],
          'profile_picture': profile['profile_picture'],
          'status': base['status'],
          'isRequester': base['isRequester'],
          'friendshipId': base['friendshipId'],
          ...challengeState,
          'unreadCount': unreadBySender[otherId] ?? 0,
          'lastMessageAt': lastMessageAtByFriend[otherId],
        });
      }

      result.sort((a, b) {
        int rank(Map<String, dynamic> x) {
          // Incoming friend requests first so they don't get lost in the list.
          final isIncomingRequest =
              x['status'] == 'pending' && x['isRequester'] != true;
          if (isIncomingRequest) return -1;
          final hasActive = x['hasActiveChallenge'] == true;
          if (hasActive) return 0;
          return 4;
        }

        final ra = rank(a);
        final rb = rank(b);
        if (ra != rb) return ra.compareTo(rb);

        final ta = a['lastMessageAt'] as DateTime?;
        final tb = b['lastMessageAt'] as DateTime?;
        if (ta != null || tb != null) {
          if (ta == null) return 1;
          if (tb == null) return -1;
          final c = tb.compareTo(ta);
          if (c != 0) return c;
        }

        final ua = (a['unreadCount'] ?? 0) as int;
        final ub = (b['unreadCount'] ?? 0) as int;
        if (ua != ub) return ub.compareTo(ua);

        final na = (a['username'] ?? '').toString();
        final nb = (b['username'] ?? '').toString();
        return na.compareTo(nb);
      });

      return result;
    } catch (e) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> loadIncomingChallenges() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser!.id;
    final cutoffIso = _pendingInviteCutoff(
      _activeDailyStartLocal(),
    ).toUtc().toIso8601String();

    try {
      await _cleanupExpiredPendingChallenges();
      List<dynamic> challenges;
      try {
        challenges = await client
            .from("challenges")
            .select()
            .eq("challenged_id", userId)
            .eq("status", "pending")
            .gte("created_at", cutoffIso)
            .order("created_at", ascending: false);
      } catch (_) {
        challenges = await client
            .from("challenges")
            .select()
            .eq("challenged_id", userId)
            .filter("completed_at", "is", null)
            .gte("created_at", cutoffIso)
            .order("created_at", ascending: false);
      }

      final challengerIds = challenges
          .map((c) => c['challenger_id'] as String)
          .toSet()
          .toList();
      Map<String, Map<String, dynamic>> profiles = {};
      if (challengerIds.isNotEmpty) {
        final profilesResult = await client
            .from("users_profile")
            .select("id, username, profile_picture")
            .inFilter("id", challengerIds);
        for (var profile in profilesResult) {
          profiles[profile['id']] = profile;
        }
      }

      return challenges.map<Map<String, dynamic>>((c) {
        final challengerId = c['challenger_id'] as String;
        final profile =
            profiles[challengerId] ??
            {'username': 'Unknown', 'profile_picture': null};
        return {
          ...c,
          'challenger_username': profile['username'],
          'challenger_profile_picture': profile['profile_picture'],
        };
      }).toList();
    } catch (e) {
      return [];
    }
  }

  Future<bool> addFriend() async {
    if (usernameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t("Bitte gib einen Benutzernamen ein", "Please enter a username"),
          ),
        ),
      );
      return false;
    }

    setState(() => loading = true);
    try {
      final client = Supabase.instance.client;
      final currentUserId = client.auth.currentUser!.id;
      final user = await client
          .from("users_profile")
          .select("id")
          .eq("username", usernameCtrl.text.trim())
          .maybeSingle();
      if (user == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(t("Benutzer nicht gefunden", "User not found")),
            ),
          );
        }
        setState(() => loading = false);
        return false;
      }
      final friendId = user['id'];
      if (friendId == currentUserId) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  "Du kannst dich selbst nicht hinzuf\u00fcgen",
                  "You cannot add yourself",
                ),
              ),
            ),
          );
        }
        setState(() => loading = false);
        return false;
      }
      final blockStatus = await BlockService.loadRelationStatus(
        friendId.toString(),
      );
      if (blockStatus.isBlocked) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  "Diese Person ist blockiert oder hat dich blockiert",
                  "This person is blocked or has blocked you",
                ),
              ),
            ),
          );
        }
        setState(() => loading = false);
        return false;
      }
      final existingRequest = await client
          .from("friends")
          .select()
          .or(
            "and(user_id.eq.$currentUserId,friend_id.eq.$friendId),and(user_id.eq.$friendId,friend_id.eq.$currentUserId)",
          )
          .maybeSingle();
      if (existingRequest != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t("Anfrage existiert bereits", "Request already exists"),
              ),
            ),
          );
        }
        setState(() => loading = false);
        return false;
      }
      await client.from("friends").insert({
        "user_id": currentUserId,
        "friend_id": friendId,
        "status": "pending",
      });
      await AnalyticsService.logInviteSent(type: 'friend_request');
      FriendDiscoveryService.invalidateSuggestionsForCurrentUser();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t("Freundschaftsanfrage gesendet!", "Friend request sent!"),
            ),
          ),
        );
        usernameCtrl.clear();
        setState(() {});
      }
      setState(() => loading = false);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
      setState(() => loading = false);
      return false;
    }
  }

  Future<bool> acceptFriend(String friendshipId) async {
    final client = Supabase.instance.client;
    try {
      await client
          .from("friends")
          .update({"status": "accepted"})
          .eq("id", friendshipId);
      FriendDiscoveryService.invalidateSuggestionsForCurrentUser();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t("Freundschaftsanfrage akzeptiert!", "Friend request accepted!"),
            ),
          ),
        );
        setState(() {
          _friendsFuture = loadFriends();
        });
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
      return false;
    }
  }

  Future<bool> removeFriend(String friendshipId) async {
    final client = Supabase.instance.client;
    try {
      await client.from("friends").delete().eq("id", friendshipId);
      FriendDiscoveryService.invalidateSuggestionsForCurrentUser();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t("Entfernt", "Removed"))));
        setState(() {
          _friendsFuture = loadFriends();
        });
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
      return false;
    }
  }

  Future<void> _openFriendRequests(List<Map<String, dynamic>> requests) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FriendRequestsScreen(
          requests: requests,
          onAccept: acceptFriend,
          onRemove: removeFriend,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _friendsFuture = loadFriends();
    });
  }

  /// WhatsApp-"Archived"-style row: pending requests live behind one entry
  /// at the top instead of between the friends.
  Widget _buildFriendRequestsEntry(
    List<Map<String, dynamic>> requests, {
    EdgeInsetsGeometry margin = const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 4,
    ),
  }) {
    final accentGreen = Theme.of(context).colorScheme.primary;
    final incoming = requests.where((r) => r['isRequester'] != true).length;
    final outgoing = requests.length - incoming;
    final parts = <String>[
      if (incoming > 0)
        incoming == 1
            ? t('1 neue Anfrage', '1 new request')
            : t('$incoming neue Anfragen', '$incoming new requests'),
      if (outgoing > 0) t('$outgoing gesendet', '$outgoing sent'),
    ];

    return Padding(
      padding: margin,
      child: Material(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            HapticFeedback.selectionClick();
            _openFriendRequests(requests);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: incoming > 0
                    ? accentGreen.withValues(alpha: 0.55)
                    : const Color(0xFF2A2A2A),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accentGreen.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.person_add_alt_1_rounded,
                    color: accentGreen,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('Freundschaftsanfragen', 'Friend requests'),
                        style: _inter.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        parts.join(' · '),
                        style: _inter.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFFAAAAAA),
                        ),
                      ),
                    ],
                  ),
                ),
                if (incoming > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: accentGreen,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$incoming',
                      style: _inter.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF10160F),
                      ),
                    ),
                  ),
                const SizedBox(width: 6),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFFAAAAAA),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> hasUserEarnedJokerToday() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser!.id;
    try {
      final today = DateTime.now().toIso8601String().split('T')[0];
      final completedChallenges = await client
          .from("challenges")
          .select("id")
          .eq("winner_id", userId)
          .gte("completed_at", "${today}T00:00:00")
          .limit(1);

      if (completedChallenges.isNotEmpty) return true;

      final profile = await client
          .from("users_profile")
          .select("joker_used_today")
          .eq("id", userId)
          .maybeSingle();

      return profile != null && profile['joker_used_today'] == true;
    } catch (e) {
      AppLogger.debug("Error checking joker status: $e");
      return false;
    }
  }

  Future<void> sendChallenge(String friendId, String friendName) async {
    _updateChallengeLoadingState(friendId, true);
    try {
      await _cleanupExpiredPendingChallenges(force: true);
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser!.id;
      // created_at is UTC (set by the server).
      final cutoffIso = _activeDailyStartLocal().toUtc().toIso8601String();
      final existingChallenge = await client
          .from("challenges")
          .select()
          .or(
            "and(challenger_id.eq.$userId,challenged_id.eq.$friendId),and(challenger_id.eq.$friendId,challenged_id.eq.$userId)",
          )
          .inFilter("status", ["pending", "accepted"])
          .gte("created_at", cutoffIso)
          .limit(1);
      if (existingChallenge.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  "Du hast in dieser Daily Quest bereits ein Duell mit diesem User",
                  "You already had a duel with this user in this Daily Quest",
                ),
              ),
            ),
          );
        }
        _updateChallengeLoadingState(friendId, false);
        return;
      }
      await client.from("challenges").insert({
        "challenger_id": userId,
        "challenged_id": friendId,
        "status": "pending",
        "created_at": DateTime.now().toIso8601String(),
        "completed_at": null,
        "winner_id": null,
      });
      // Flip the local friend flags immediately so the yellow border lands in
      // the same frame the bolt animation ends — otherwise it only appears
      // ~1s later when the realtime/refresh round-trip completes.
      final resolvedFriends = await _friendsFuture;
      if (resolvedFriends != null) {
        for (final entry in resolvedFriends) {
          if ((entry['id'] ?? '').toString() == friendId) {
            entry['hasPendingChallenge'] = true;
            entry['hasChallengeToday'] = true;
            break;
          }
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                "Duell an $friendName gesendet!",
                "Duel sent to $friendName!",
              ),
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
    _updateChallengeLoadingState(friendId, false);
  }

  Future<void> acceptChallenge(String challengeId) async {
    if (_acceptingChallengeIds.contains(challengeId)) return;
    if (mounted) {
      setState(() => _acceptingChallengeIds.add(challengeId));
    }

    try {
      final client = Supabase.instance.client;

      final pvpChallenges = await client.from("pvp_quest_challenges").select();
      final normalizedChallenges = List<Map<String, dynamic>>.from(
        (pvpChallenges as List).map((e) => Map<String, dynamic>.from(e)),
      );
      if (normalizedChallenges.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  "Keine Duell-Aufgaben verfügbar",
                  "No duel tasks available",
                ),
              ),
            ),
          );
        }
        return;
      }

      final todaysChallenges = _dailyPvpChallengeSelection(
        normalizedChallenges,
        maxCount: 6,
      );

      if (todaysChallenges.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  "Für deinen aktuellen Bereich sind noch keine Duell-Aufgaben verfügbar.",
                  "There are no duel tasks available for your current scope yet.",
                ),
              ),
            ),
          );
        }
        return;
      }

      if (!mounted) return;
      final picked = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ChallengeWheelDialog(challenges: todaysChallenges),
      );
      if (picked == null) return;

      final expiresAt = DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 30))
          .toIso8601String();
      final description = _composeChallengeDescription(picked);

      await client
          .from("challenges")
          .update({
            "status": "accepted",
            "expires_at": expiresAt,
            "challenger_expires_at": expiresAt,
            "challenged_expires_at": expiresAt,
            "pvp_challenge_id": picked['id'],
            "description": description,
          })
          .eq("id", challengeId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                "Duell akzeptiert! Du hast 30 Minuten Zeit!",
                "Duel accepted! You have 30 minutes!",
              ),
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
    } finally {
      if (mounted) {
        setState(() => _acceptingChallengeIds.remove(challengeId));
      }
    }
  }

  Future<void> declineChallenge(String challengeId) async {
    try {
      final client = Supabase.instance.client;
      await client
          .from("challenges")
          .update({"status": "declined"})
          .eq("id", challengeId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t("Duell abgelehnt.", "Duel declined.")),
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

  Future<void> _showChallengePhotoUpload(Map<String, dynamic> friend) async {
    XFile? file;
    try {
      file = await picker.pickImage(source: ImageSource.camera);
    } on PlatformException catch (e) {
      if (mounted) {
        final msg = isImagePickerAccessDenied(e)
            ? imagePickerAccessDeniedMessage(cameraOnly: true)
            : t(
                'Kamera konnte nicht geöffnet werden (${e.code}).',
                'Could not open camera (${e.code}).',
              );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
      return;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.describe(e))));
      }
      return;
    }
    if (file == null) return;
    if (!mounted) return;

    // Validate image before upload (size + MIME type)
    final imgVal = await validateImageFile(file.path);
    if (!imgVal.isValid) {
      if (mounted) {
        final msg = imgVal.error == ImageValidationError.tooLarge
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

    setState(() => uploadingStates[friend['id']] = true);
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser!.id;
      final challengeId = friend['activeChallenge']['id'];

      final challengeData = await client
          .from("challenges")
          .select(
            "challenger_id, challenged_id, status, completed_at, winner_id, expires_at, challenger_expires_at, challenged_expires_at, description",
          )
          .eq("id", challengeId)
          .single();

      final status = (challengeData['status'] ?? '').toString();
      final completedAt = challengeData['completed_at'];
      final winnerId = challengeData['winner_id'];
      if (status != 'accepted' || completedAt != null || winnerId != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Duell ist bereits beendet.',
                  'Duel is already finished.',
                ),
              ),
            ),
          );
        }
        return;
      }

      final challengerId = (challengeData['challenger_id'] ?? '').toString();
      final challengedId = (challengeData['challenged_id'] ?? '').toString();

      try {
        final ownChallengePhotos = await client
            .from("photos")
            .select("id")
            .eq("challenge_id", challengeId)
            .eq("user_id", userId)
            .limit(1);
        if (ownChallengePhotos.isNotEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  t(
                    "Du hast für dieses Duell bereits ein Foto gepostet.",
                    "You already posted a photo for this duel.",
                  ),
                ),
              ),
            );
          }
          return;
        }
      } catch (_) {
        // Best-effort check only.
      }

      final fallbackExpiresAtStr = challengeData['expires_at'] as String?;
      final myExpiresAtStr = (userId == challengerId)
          ? (challengeData['challenger_expires_at'] as String? ??
                fallbackExpiresAtStr)
          : (challengeData['challenged_expires_at'] as String? ??
                fallbackExpiresAtStr);

      if (myExpiresAtStr != null) {
        final expiresAt = DateTime.parse(myExpiresAtStr);
        if (DateTime.now().isAfter(expiresAt)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  t(
                    "Zeit abgelaufen! Das Duell ist vorbei.",
                    "Time's up! The duel is over.",
                  ),
                ),
              ),
            );
          }
          return;
        }
      }

      final partnerId = challengerId == userId ? challengedId : challengerId;
      final fileName = "${DateTime.now().millisecondsSinceEpoch}.jpg";
      final compressedPvpFile = await compressPhotoForUpload(file.path);
      await client.storage
          .from("photos")
          .upload("$userId/$fileName", compressedPvpFile);
      final publicUrl = client.storage
          .from("photos")
          .getPublicUrl("$userId/$fileName");

      try {
        await client.from("photos").insert({
          "user_id": userId,
          "url": publicUrl,
          "created_at": DateTime.now().toUtc().toIso8601String(),
          "is_challenge_photo": true,
          "challenge_id": challengeId,
          "challenge_description": challengeData['description'],
          "challenge_expires_at": challengeData['expires_at'],
        });
      } catch (_) {
        // Never retry without the duel attached: such a photo would count as
        // today's quest post. Remove the uploaded file instead.
        try {
          await client.storage.from("photos").remove(["$userId/$fileName"]);
        } catch (_) {}
        rethrow;
      }

      notifyPostDataChanged();
      await client.from("messages").insert({
        "sender_id": userId,
        "receiver_id": partnerId,
        "message": "Duell-Foto gepostet: $publicUrl",
        "created_at": DateTime.now().toUtc().toIso8601String(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                "Foto gepostet! Die Auswertung läuft bis zur nächsten Daily Quest.",
                "Photo posted! Voting runs until the next Daily Quest.",
              ),
            ),
          ),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMapper.describe(
              e,
              whatDe: "Fehler beim Upload",
              whatEn: "Upload error",
            )),
          ),
        );
      }
    } finally {
      // Also after the early returns above (duel over, already posted).
      if (mounted) {
        setState(() => uploadingStates[friend['id']] = false);
      }
    }
  }

  Future<void> _sabotageActiveChallenge(Map<String, dynamic> friend) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    final friendId = (friend['id'] ?? '').toString();
    final active = friend['activeChallenge'];
    final challengeId = (active is Map ? (active['id'] ?? '') : '').toString();
    if (friendId.isEmpty || challengeId.isEmpty) return;

    if (!mounted) return;
    setState(() => sabotageLoadingStates[friendId] = true);

    try {
      await client.rpc(
        'sabotage_challenge',
        params: {'p_challenge_id': challengeId, 'p_minutes': 5},
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Sabotiert! -5 Minuten.', 'Sabotaged! -5 minutes.')),
        ),
      );

      // Force a refresh so the countdown updates.
      setState(() {});
    } on PostgrestException catch (e) {
      if (!mounted) return;
      final msg = e.message.toLowerCase();
      String text;
      if (msg.contains('not_enough_jokers')) {
        text = t(
          'Nicht genug Joker (1 n\u00f6tig).',
          'Not enough jokers (need 1).',
        );
      } else if (msg.contains('already_sabotaged')) {
        text = t(
          'Du hast dieses Duell schon sabotiert.',
          'You already sabotaged this duel.',
        );
      } else if (msg.contains('challenge_expired')) {
        text = t(
          'Zu sp\u00e4t - Duell ist vorbei.',
          'Too late - duel ended.',
        );
      } else {
        text = t('Sabotage fehlgeschlagen.', 'Sabotage failed.');
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Sabotage fehlgeschlagen.', 'Sabotage failed.')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => sabotageLoadingStates[friendId] = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Instagram-style dark colors
    const darkBg = Color(0xFF121212);
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final accentGreen = Theme.of(
      context,
    ).colorScheme.primary; // Das bisherige Grün

    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkBg,
        centerTitle: false,
        titleSpacing: 20,
        title: Text(
          t("Freunde", "Friends"),
          style: _inter.copyWith(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: textPrimary,
          ),
        ),
        elevation: 0,
      ),
      body: Column(
        children: [
          _buildDuelResults(),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _incomingChallengesFuture,
            builder: (context, snapshot) {
              final loaded = snapshot.data ?? const [];
              if (loaded.isEmpty) return const SizedBox.shrink();

              // Re-evaluates the countdown locally once per 30 s (no
              // requests); expired invites drop out of the list right away.
              return _PeriodicRebuild(
                interval: const Duration(seconds: 30),
                builder: (context) {
                  final nowUtc = DateTime.now().toUtc();
                  final challenges = loaded
                      .where((c) => !isDuelInviteExpired(c, nowUtc))
                      .toList(growable: false);
                  // One cleanup request per newly expired invite marks it
                  // declined on the server.
                  final newlyExpired = loaded
                      .where((c) => isDuelInviteExpired(c, nowUtc))
                      .map((c) => (c['id'] ?? '').toString())
                      .where(_handledExpiredInviteIds.add)
                      .toList(growable: false);
                  if (newlyExpired.isNotEmpty) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _cleanupExpiredPendingChallenges(force: true),
                    );
                  }
                  if (challenges.isEmpty) return const SizedBox.shrink();

                  return Container(
                    color: cardDark,
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t("Duelle", "Duels"),
                          style: _inter.copyWith(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Colors.orange.shade700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 170,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: challenges.length,
                            // ignore: deprecated_member_use
                            cacheExtent: 500,
                            addAutomaticKeepAlives: false,
                            addRepaintBoundaries: true,
                            itemBuilder: (context, i) {
                              final challenge = challenges[i];
                              final challengerName =
                                  (challenge['challenger_username'] ?? 'Unknown')
                                      .toString();
                              final challengerPicRaw =
                                  challenge['challenger_profile_picture'];
                              final challengerPic = challengerPicRaw == null
                                  ? ''
                                  : challengerPicRaw.toString().trim();
                              final challengerId =
                                  (challenge['challenger_id'] ?? '').toString();
                              final description = (challenge['description'] ?? '')
                                  .toString();
                              final normalizedDescription = description
                                  .trim()
                                  .toLowerCase();
                              final isGenericChallengeText =
                                  normalizedDescription.isEmpty ||
                                  normalizedDescription == 'challenge' ||
                                  normalizedDescription == 'new challenge' ||
                                  normalizedDescription == 'neue challenge';
                              final challengeInfoText = isGenericChallengeText
                                  ? t(
                                      'hat dich herausgefordert!',
                                      'challenged you!',
                                    )
                                  : description;
                              final challengeInfoColor = isGenericChallengeText
                                  ? const Color(0xFFFF8A00)
                                  : textSecondary;
                              final challengeId = (challenge['id'] ?? '')
                                  .toString();
                              final isAccepting = _acceptingChallengeIds.contains(
                                challengeId,
                              );

                              return Container(
                                width: 220,
                                margin: const EdgeInsets.only(right: 10),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: cardDark,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: const Color.fromARGB(255, 255, 127, 52),
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color.fromARGB(
                                        255,
                                        255,
                                        166,
                                        0,
                                      ).withValues(alpha: 0.12),
                                      blurRadius: 8,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        GestureDetector(
                                          onTap: challengerId.isNotEmpty
                                              ? () => Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) => ProfileScreen(
                                                      userId: challengerId,
                                                    ),
                                                  ),
                                                )
                                              : null,
                                          child: CircleAvatar(
                                            radius: 16,
                                            backgroundColor: Colors.black,
                                            backgroundImage:
                                                challengerPic.isNotEmpty
                                                ? sideQuestCachedImageProvider(
                                                    challengerPic,
                                                    cacheWidth: sideQuestCacheWidth(
                                                      context,
                                                      32,
                                                    ),
                                                    cacheHeight:
                                                        sideQuestCacheWidth(
                                                          context,
                                                          32,
                                                        ),
                                                  )
                                                : null,
                                            child: challengerPic.isEmpty
                                                ? Text(
                                                    challengerName.isNotEmpty
                                                        ? challengerName[0]
                                                              .toUpperCase()
                                                        : '?',
                                                    style: _inter.copyWith(
                                                      color: Colors.white,
                                                      fontWeight: FontWeight.w700,
                                                      fontSize: 12,
                                                    ),
                                                  )
                                                : null,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            challengerName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: _inter.copyWith(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color: textPrimary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Expanded(
                                      child: Text(
                                        challengeInfoText,
                                        maxLines: 4,
                                        overflow: TextOverflow.ellipsis,
                                        style: _inter.copyWith(
                                          fontSize: 13,
                                          height: 1.25,
                                          color: challengeInfoColor,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      duelInviteTimeLeftLabel(
                                        Map<String, dynamic>.from(challenge),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _inter.copyWith(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.orange.shade300,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: appGreen,
                                              foregroundColor: Colors.white,
                                              elevation: 0,
                                              padding: const EdgeInsets.symmetric(
                                                vertical: 10,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(
                                                  18,
                                                ),
                                              ),
                                            ),
                                            onPressed: () async {
                                              if (challengeId.isEmpty) return;
                                              if (isDuelInviteExpired(
                                                challenge,
                                                DateTime.now().toUtc(),
                                              )) {
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  SnackBar(
                                                    content: Text(
                                                      t(
                                                        'Diese Herausforderung ist abgelaufen.',
                                                        'This challenge has expired.',
                                                      ),
                                                    ),
                                                  ),
                                                );
                                                setState(() {});
                                                return;
                                              }
                                              await acceptChallenge(challengeId);
                                            },
                                            icon: isAccepting
                                                ? const SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.white,
                                                        ),
                                                  )
                                                : const Icon(
                                                    Icons.camera_alt,
                                                    size: 16,
                                                    color: Colors.white,
                                                  ),
                                            label: Text(
                                              isAccepting
                                                  ? t('Lädt...', 'Loading...')
                                                  : t('Annehmen', 'Accept'),
                                              style: _inter.copyWith(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        SizedBox(
                                          width: 48,
                                          child: ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFF2A2A2A,
                                              ),
                                              foregroundColor: const Color(
                                                0xFFFF4D4F,
                                              ),
                                              elevation: 0,
                                              padding: const EdgeInsets.symmetric(
                                                vertical: 10,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(
                                                  18,
                                                ),
                                              ),
                                            ),
                                            onPressed: isAccepting
                                                ? null
                                                : () async {
                                                    if (challengeId.isEmpty) return;
                                                    await declineChallenge(
                                                      challengeId,
                                                    );
                                                  },
                                            child: Text(
                                              t('X', 'X'),
                                              style: _inter.copyWith(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: const Color(0xFFFF4D4F),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: usernameCtrl,
                  focusNode: _usernameFocusNode,
                  style: _inter.copyWith(color: textPrimary),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: cardDark,
                    hintText: t("Benutzername", "Username"),
                    hintStyle: _inter.copyWith(color: textSecondary),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                ),
                if (_usernameSuggestLoading || _usernameSuggestions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 220),
                      decoration: BoxDecoration(
                        color: cardDark,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF2A2A2A)),
                      ),
                      child: _usernameSuggestLoading
                          ? Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: accentGreen,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    t('Suche...', 'Searching...'),
                                    style: _inter.copyWith(
                                      fontSize: 13,
                                      color: textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: _usernameSuggestions.length,
                              separatorBuilder: (context, _) => Divider(
                                height: 1,
                                color: const Color(0xFF2A2A2A),
                              ),
                              itemBuilder: (context, i) {
                                final u = _usernameSuggestions[i];
                                final name = (u['username'] ?? '').toString();
                                final pic = u['profile_picture'];

                                return InkWell(
                                  onTap: () {
                                    // Tap on a search result opens the user's
                                    // profile — sending the friend request via
                                    // the input's "Add" button gave no
                                    // feedback, so this is the discoverable
                                    // path. The profile has its own
                                    // "Add friend" button.
                                    final tappedUserId = (u['id'] ?? '')
                                        .toString();
                                    setState(() {
                                      _usernameSuggestions = [];
                                      _usernameSuggestLoading = false;
                                    });
                                    _usernameFocusNode.unfocus();
                                    if (tappedUserId.isEmpty) return;
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ProfileScreen(
                                          userId: tappedUserId,
                                        ),
                                      ),
                                    );
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 16,
                                          backgroundColor: Colors.black,
                                          backgroundImage:
                                              (pic != null &&
                                                  pic
                                                      .toString()
                                                      .trim()
                                                      .isNotEmpty)
                                              ? sideQuestCachedImageProvider(
                                                  pic.toString(),
                                                  cacheWidth:
                                                      sideQuestCacheWidth(
                                                        context,
                                                        32,
                                                      ),
                                                  cacheHeight:
                                                      sideQuestCacheWidth(
                                                        context,
                                                        32,
                                                      ),
                                                )
                                              : null,
                                          child:
                                              (pic == null ||
                                                  pic.toString().trim().isEmpty)
                                              ? Text(
                                                  name.isNotEmpty
                                                      ? name[0].toUpperCase()
                                                      : '?',
                                                  style: _inter.copyWith(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 12,
                                                  ),
                                                )
                                              : null,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            name,
                                            style: _inter.copyWith(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: textPrimary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                const SizedBox(height: 12),
                AddFriendActions(
                  loading: loading,
                  onAdd: addFriend,
                  onShare: (buttonContext) => shareSideQuestInvite(
                    surface: 'friends_header',
                    context: buttonContext,
                  ),
                ),
              ],
            ),
          ),
          Divider(color: const Color(0xFF2A2A2A)),
          Expanded(
            child: FutureBuilder(
              future: _friendsFuture,
              builder: (context, snapshot) {
                Widget content;

                if (!snapshot.hasData) {
                  content = Center(
                    key: const ValueKey('friends_loading'),
                    child: CircularProgressIndicator(color: accentGreen),
                  );
                } else {
                  final allFriends = snapshot.data!;
                  final requests = allFriends
                      .where((f) => f['status'] == 'pending')
                      .toList(growable: false);
                  final friends = allFriends
                      .where((f) => f['status'] != 'pending')
                      .toList(growable: false);
                  final hasRequests = requests.isNotEmpty;
                  if (friends.isEmpty) {
                    content = ListView(
                      key: const ValueKey('friends_empty'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(16, hasRequests ? 8 : 24, 16, 24),
                      children: [
                        if (hasRequests) ...[
                          _buildFriendRequestsEntry(
                            requests,
                            margin: EdgeInsets.zero,
                          ),
                          const SizedBox(height: 24),
                        ],
                        // Cold-start: without friends the feed stays dead —
                        // make inviting the primary action on this screen.
                        const InviteProgressCard(
                          friendCount: 0,
                          surface: 'friends_empty',
                        ),
                        _buildSuggestionsSection(
                          excludeUserIds: {
                            for (final f in requests)
                              if ((f['id'] ?? '').toString().isNotEmpty)
                                f['id'].toString(),
                          },
                          forceVisible: true,
                        ),
                      ],
                    );
                  } else {
                    final excludeIds = <String>{};
                    for (final f in allFriends) {
                      final id = (f['id'] ?? '').toString();
                      if (id.isNotEmpty) excludeIds.add(id);
                    }

                    final acceptedCount = friends
                        .where((f) => f['status'] == 'accepted')
                        .length;
                    final showInvite = acceptedCount < kInviteFriendGoal;
                    final headerCount =
                        (hasRequests ? 1 : 0) + (showInvite ? 1 : 0);

                    content = ListView.builder(
                      key: const ValueKey('friends_list'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(0, 8, 0, 140),
                      itemCount: friends.length + 1 + headerCount,
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: true,
                      itemBuilder: (context, rawIndex) {
                        if (hasRequests && rawIndex == 0) {
                          return _buildFriendRequestsEntry(requests);
                        }
                        if (showInvite &&
                            rawIndex == (hasRequests ? 1 : 0)) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                            child: InviteProgressCard(
                              friendCount: acceptedCount,
                              surface: 'friends_progress',
                            ),
                          );
                        }
                        final i = rawIndex - headerCount;
                        if (i == friends.length) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                            child: _buildSuggestionsSection(
                              excludeUserIds: excludeIds,
                            ),
                          );
                        }

                        final friend = friends[i];
                        final status = friend['status'];
                        final isRequester = friend['isRequester'];
                        final friendshipId = friend['friendshipId'];

                        // Gestaffelte Einblend-Animation
                        return FadeSlideIn(
                          duration: Duration(
                            milliseconds: 300 + (i * 40).clamp(0, 200),
                          ),
                          curve: kCurveStandard,
                          offsetY: kSlideEntryOffset,
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  (friend['hasPendingChallenge'] ||
                                      friend['hasActiveChallenge'])
                                  ? Colors.amber.withValues(alpha: 0.15)
                                  : cardDark,
                              borderRadius: BorderRadius.circular(10),
                              border:
                                  (friend['hasPendingChallenge'] ||
                                      friend['hasActiveChallenge'])
                                  ? Border.all(color: Colors.amber, width: 2)
                                  : Border.all(
                                      color: const Color(0xFF2A2A2A),
                                      width: 1,
                                    ),
                            ),
                            child: Column(
                              children: [
                                if (friend['hasActiveChallenge'] &&
                                    friend['activeChallenge'] != null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Container(
                                      padding: const EdgeInsets.fromLTRB(
                                        14,
                                        12,
                                        14,
                                        12,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF2A2210),
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: Colors.amber,
                                          width: 1.4,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(
                                                Icons.flash_on,
                                                color: Colors.amber,
                                                size: 18,
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  t(
                                                    'Duell läuft – deine Aufgabe:',
                                                    'Duel on – your task:',
                                                  ),
                                                  style: _inter.copyWith(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w800,
                                                    color: Colors.amber,
                                                  ),
                                                ),
                                              ),
                                              _ChallengeCountdown(
                                                expiresAt:
                                                    friend['activeChallenge']['effective_expires_at'] ??
                                                    friend['activeChallenge']['expires_at'],
                                                onExpired: () {
                                                  final challengeId =
                                                      (friend['activeChallenge']['id'] ??
                                                              '')
                                                          .toString();
                                                  final partnerId =
                                                      (friend['id'] ?? '')
                                                          .toString();
                                                  if (challengeId.isEmpty ||
                                                      partnerId.isEmpty) {
                                                    return;
                                                  }
                                                  unawaited(
                                                    _failExpiredChallengeIfNobodyPosted(
                                                      challengeId: challengeId,
                                                      partnerId: partnerId,
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            friend['activeChallenge']['description'] ??
                                                t('Duell', 'Duel'),
                                            style: _inter.copyWith(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w800,
                                              color: Colors.white,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            t(
                                              'Poste dein Foto, bevor die Zeit abläuft. Danach stimmen alle bis zur nächsten Quest ab – mehr Likes gewinnt.',
                                              'Post your photo before time runs out. Then everyone votes until the next quest – most likes wins.',
                                            ),
                                            style: _inter.copyWith(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                              color: const Color(0xFFCFC4A8),
                                              height: 1.35,
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          SizedBox(
                                            width: double.infinity,
                                            height: 44,
                                            child: FilledButton.icon(
                                              onPressed:
                                                  uploadingStates[friend['id']] ==
                                                      true
                                                  ? null
                                                  : () =>
                                                        _showChallengePhotoUpload(
                                                          friend,
                                                        ),
                                              icon:
                                                  uploadingStates[friend['id']] ==
                                                      true
                                                  ? const SizedBox(
                                                      width: 18,
                                                      height: 18,
                                                      child:
                                                          CircularProgressIndicator(
                                                            strokeWidth: 2.2,
                                                            color: Colors.black,
                                                          ),
                                                    )
                                                  : const Icon(
                                                      Icons.camera_alt_rounded,
                                                      size: 20,
                                                    ),
                                              label: Text(
                                                t(
                                                  'Duell-Foto aufnehmen',
                                                  'Take duel photo',
                                                ),
                                                style: _inter.copyWith(
                                                  fontSize: 14.5,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              style: FilledButton.styleFrom(
                                                backgroundColor: Colors.amber,
                                                foregroundColor: Colors.black,
                                                disabledBackgroundColor: Colors
                                                    .amber
                                                    .withValues(alpha: 0.5),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  dense: false,
                                  minLeadingWidth: 50,
                                  visualDensity: const VisualDensity(
                                    horizontal: -1,
                                    vertical: -1,
                                  ),
                                  leading: GestureDetector(
                                    onTap: friend['id'] != null
                                        ? () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => ProfileScreen(
                                                userId: friend['id'].toString(),
                                              ),
                                            ),
                                          )
                                        : null,
                                    child: CircleAvatar(
                                      radius: 22,
                                      backgroundColor: Colors.black,
                                      backgroundImage:
                                          friend['profile_picture'] != null
                                          ? sideQuestCachedImageProvider(
                                              friend['profile_picture'],
                                              cacheWidth: sideQuestCacheWidth(
                                                context,
                                                44,
                                              ),
                                              cacheHeight: sideQuestCacheWidth(
                                                context,
                                                44,
                                              ),
                                            )
                                          : null,
                                      child: friend['profile_picture'] == null
                                          ? Text(
                                              (friend['username'] ?? 'U')[0]
                                                  .toUpperCase(),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 15,
                                              ),
                                            )
                                          : null,
                                    ),
                                  ),
                                  title: Text(
                                    friend['username'],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: _inter.copyWith(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                      color: textPrimary,
                                    ),
                                  ),
                                  subtitle: status == 'pending'
                                      ? Text(
                                          isRequester
                                              ? t(
                                                  'Anfrage gesendet',
                                                  'Request sent',
                                                )
                                              : t(
                                                  'M\u00f6chte dein Freund sein \u2013 annehmen?',
                                                  'Wants to be your friend \u2013 accept?',
                                                ),
                                          style: _inter.copyWith(
                                            fontSize: 12,
                                            color: isRequester
                                                ? textSecondary
                                                : accentGreen,
                                            fontWeight: isRequester
                                                ? FontWeight.w400
                                                : FontWeight.w700,
                                          ),
                                        )
                                      : null,
                                  trailing: status == 'pending'
                                      ? Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (!isRequester)
                                              IconButton(
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints.tightFor(
                                                      width: 36,
                                                      height: 36,
                                                    ),
                                                visualDensity:
                                                    const VisualDensity(
                                                      horizontal: -2,
                                                      vertical: -2,
                                                    ),
                                                splashRadius: 18,
                                                icon: const Icon(
                                                  Icons.check,
                                                  color: Colors.green,
                                                  size: 22,
                                                ),
                                                onPressed: () =>
                                                    acceptFriend(friendshipId),
                                              ),
                                            IconButton(
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                    width: 36,
                                                    height: 36,
                                                  ),
                                              visualDensity:
                                                  const VisualDensity(
                                                    horizontal: -2,
                                                    vertical: -2,
                                                  ),
                                              splashRadius: 18,
                                              icon: const Icon(
                                                Icons.close,
                                                color: Colors.red,
                                                size: 22,
                                              ),
                                              onPressed: () =>
                                                  removeFriend(friendshipId),
                                            ),
                                          ],
                                        )
                                      : Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Builder(
                                              builder: (context) {
                                                final friendId =
                                                    (friend['id'] ?? '')
                                                        .toString();
                                                final isChallengeBusy =
                                                    challengeLoadingStates[friendId] ??
                                                    false;
                                                final hasRecentChallenge =
                                                    friend['hasChallengeToday'] ||
                                                    friend['hasCompletedChallengeToday'];
                                                final isBoltActive =
                                                    _animatingBoltFriendId ==
                                                        friendId ||
                                                    isChallengeBusy;

                                                return IconButton(
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      const BoxConstraints.tightFor(
                                                        width: 36,
                                                        height: 36,
                                                      ),
                                                  visualDensity:
                                                      const VisualDensity(
                                                        horizontal: -2,
                                                        vertical: -2,
                                                      ),
                                                  splashRadius: 18,
                                                  icon: _buildChallengeBoltIcon(
                                                    isActive: isBoltActive,
                                                    isDisabled:
                                                        hasRecentChallenge,
                                                  ),
                                                  tooltip: hasRecentChallenge
                                                      ? 'Duell in den letzten 24h bereits'
                                                      : 'Joker-Duell',
                                                  onPressed:
                                                      isChallengeBusy ||
                                                          hasRecentChallenge
                                                      ? null
                                                      : () async {
                                                          unawaited(
                                                            showLightningStrike(
                                                              context,
                                                            ),
                                                          );
                                                          if (friendId
                                                              .isEmpty) {
                                                            await sendChallenge(
                                                              friend['id'],
                                                              friend['username'],
                                                            );
                                                            return;
                                                          }

                                                          _startBoltAnimation(
                                                            friendId,
                                                          );

                                                          try {
                                                            await sendChallenge(
                                                              friend['id'],
                                                              friend['username'],
                                                            );
                                                          } finally {
                                                            _finishBoltAnimation(
                                                              friendId,
                                                            );
                                                          }
                                                        },
                                                );
                                              },
                                            ),
                                            IconButton(
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                    width: 36,
                                                    height: 36,
                                                  ),
                                              visualDensity:
                                                  const VisualDensity(
                                                    horizontal: -2,
                                                    vertical: -2,
                                                  ),
                                              splashRadius: 18,
                                              icon: Icon(
                                                Icons.camera_alt,
                                                color:
                                                    friend['hasActiveChallenge']
                                                    ? Colors.blue
                                                    : Colors.grey,
                                                size:
                                                    friend['hasActiveChallenge']
                                                    ? 23
                                                    : 21,
                                              ),
                                              tooltip: t(
                                                'Foto posten',
                                                'Post photo',
                                              ),
                                              onPressed:
                                                  friend['hasActiveChallenge']
                                                  ? () =>
                                                        _showChallengePhotoUpload(
                                                          friend,
                                                        )
                                                  : null,
                                            ),
                                            IconButton(
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                    width: 36,
                                                    height: 36,
                                                  ),
                                              visualDensity:
                                                  const VisualDensity(
                                                    horizontal: -2,
                                                    vertical: -2,
                                                  ),
                                              splashRadius: 18,
                                              icon: Icon(
                                                Icons.hourglass_bottom_rounded,
                                                size: 22,
                                                color:
                                                    friend['hasActiveChallenge']
                                                    ? Colors.red
                                                    : Colors.grey,
                                              ),
                                              tooltip: t(
                                                'Sabotieren (1 Joker)',
                                                'Sabotage (1 joker)',
                                              ),
                                              onPressed:
                                                  friend['hasActiveChallenge'] &&
                                                      !(sabotageLoadingStates[(friend['id'] ??
                                                                  '')
                                                              .toString()] ??
                                                          false)
                                                  ? () =>
                                                        _sabotageActiveChallenge(
                                                          friend,
                                                        )
                                                  : null,
                                            ),
                                            IconButton(
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                    width: 36,
                                                    height: 36,
                                                  ),
                                              visualDensity:
                                                  const VisualDensity(
                                                    horizontal: -2,
                                                    vertical: -2,
                                                  ),
                                              splashRadius: 18,
                                              icon: Stack(
                                                clipBehavior: Clip.none,
                                                children: [
                                                  Icon(
                                                    Icons.chat,
                                                    color: appGreen,
                                                    size: 22,
                                                  ),
                                                  if (friend['unreadCount'] > 0)
                                                    Positioned(
                                                      right: -7,
                                                      top: -7,
                                                      child: Container(
                                                        padding:
                                                            const EdgeInsets.all(
                                                              4,
                                                            ),
                                                        decoration:
                                                            const BoxDecoration(
                                                              color: Colors.red,
                                                              shape: BoxShape
                                                                  .circle,
                                                            ),
                                                        constraints:
                                                            const BoxConstraints(
                                                              minWidth: 16,
                                                              minHeight: 16,
                                                            ),
                                                        child: Center(
                                                          child: Text(
                                                            friend['unreadCount'] >
                                                                    9
                                                                ? '9+'
                                                                : friend['unreadCount']
                                                                      .toString(),
                                                            style:
                                                                const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontSize: 9,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                              onPressed: () async {
                                                final removedFriend = await Navigator.push<bool>(
                                                  context,
                                                  PageRouteBuilder(
                                                    transitionDuration:
                                                        const Duration(
                                                          milliseconds: 170,
                                                        ),
                                                    reverseTransitionDuration:
                                                        const Duration(
                                                          milliseconds: 130,
                                                        ),
                                                    pageBuilder:
                                                        (
                                                          context,
                                                          animation,
                                                          secondaryAnimation,
                                                        ) => ChatScreen(
                                                          friendId:
                                                              friend['id'],
                                                          friendUsername:
                                                              friend['username'],
                                                        ),
                                                    transitionsBuilder:
                                                        (
                                                          context,
                                                          animation,
                                                          secondaryAnimation,
                                                          child,
                                                        ) {
                                                          return FadeTransition(
                                                            opacity:
                                                                CurvedAnimation(
                                                                  parent:
                                                                      animation,
                                                                  curve: Curves
                                                                      .easeOut,
                                                                ),
                                                            child: child,
                                                          );
                                                        },
                                                  ),
                                                );
                                                if (!context.mounted) return;
                                                setState(() {});
                                                widget.onUnreadCountChanged
                                                    ?.call();
                                                if (removedFriend == true) {
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        t(
                                                          'Freund entfernt',
                                                          'Friend removed',
                                                        ),
                                                      ),
                                                    ),
                                                  );
                                                }
                                              },
                                            ),
                                          ],
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

                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, animation) {
                    final slide = Tween<Offset>(
                      begin: const Offset(0, 0.02),
                      end: Offset.zero,
                    ).animate(animation);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(position: slide, child: child),
                    );
                  },
                  child: content,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final String friendId;
  final String friendUsername;

  const ChatScreen({
    super.key,
    required this.friendId,
    required this.friendUsername,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  static const String _pendingMessagesPrefsKey = 'chat_pending_messages_v1';

  final messageCtrl = TextEditingController();
  final scrollController = ScrollController();
  final ImagePicker _chatImagePicker = ImagePicker();
  bool sending = false;
  final Set<String> _deletingMessageIds = {};
  final Map<String, List<Map<String, dynamic>>> _messageReactions = {};
  static const String _emojiThumbsUp = '\u{1F44D}';
  static const String _emojiHeart = '\u2764\uFE0F';
  static const String _emojiLaugh = '\u{1F602}';
  static const String _emojiWow = '\u{1F62E}';
  static const String _emojiSad = '\u{1F622}';
  static const String _emojiFire = '\u{1F525}';
  final List<String> _reactionEmojis = [
    _emojiThumbsUp,
    _emojiHeart,
    _emojiLaugh,
    _emojiWow,
    _emojiSad,
    _emojiFire,
  ];
  final Map<String, int> _reactionAnimTicks = {}; // "$msgId|$emoji" -> tick
  final ValueNotifier<bool> _canSend = ValueNotifier<bool>(false);
  final Set<String> _freshMessageIds = {};
  String? _pressedMessageId;

  List<Map<String, dynamic>> _messages = const [];
  bool _loadingMessages = true;
  String? _currentUserId;
  String? _friendAvatarUrl;

  RealtimeChannel? _messagesSubscription;
  RealtimeChannel? _reactionsSubscription;
  Timer? _reactionRefreshDebounce;
  final Set<String> _localReactionWriteGuards = <String>{};

  int _lastRenderedMessageCount = 0;
  bool _autoScrollScheduled = false;
  OverlayEntry? _reactionOverlayEntry;
  final Set<String> _pendingDeliveryIds = {};

  @override
  void initState() {
    super.initState();
    _currentUserId = Supabase.instance.client.auth.currentUser?.id;
    messageCtrl.addListener(_onComposerChanged);
    _markMessagesAsRead();
    _loadInitialMessages();
    _setupChatRealtime();
  }

  @override
  void dispose() {
    _dismissReactionOverlay(clearPressed: false);
    _pressedMessageId = null;
    _reactionRefreshDebounce?.cancel();
    _messagesSubscription?.unsubscribe();
    _reactionsSubscription?.unsubscribe();
    messageCtrl.removeListener(_onComposerChanged);
    messageCtrl.dispose();
    _canSend.dispose();
    scrollController.dispose();
    super.dispose();
  }

  void _onComposerChanged() {
    final next = messageCtrl.text.trim().isNotEmpty;
    if (_canSend.value != next) _canSend.value = next;
  }

  void _setPressedMessage(String? messageId) {
    if (!mounted) {
      _pressedMessageId = messageId;
      return;
    }
    setState(() {
      _pressedMessageId = messageId;
    });
  }

  void _dismissReactionOverlay({bool clearPressed = true}) {
    try {
      _reactionOverlayEntry?.remove();
    } catch (_) {
      // ignore
    }
    _reactionOverlayEntry = null;

    if (!clearPressed) return;
    if (!mounted) {
      _pressedMessageId = null;
      return;
    }
    setState(() {
      _pressedMessageId = null;
    });
  }

  void _bumpReactionAnim(String messageId, String emoji) {
    final k = '$messageId|$emoji';
    _reactionAnimTicks[k] = (_reactionAnimTicks[k] ?? 0) + 1;
  }

  void _scrollToBottom() {
    if (!mounted || !scrollController.hasClients) return;
    final position = scrollController.position;
    if (!position.hasContentDimensions) return;
    final target = position.minScrollExtent;
    try {
      scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    } catch (_) {
      // ignore
    }
  }

  bool _isNearBottom() {
    if (!scrollController.hasClients) return true;
    return scrollController.position.pixels <= 48;
  }

  void _scrollToBottomStabilized({int retries = 1}) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToBottom();
      if (retries <= 0) return;
      Future.delayed(const Duration(milliseconds: 60), () {
        if (!mounted) return;
        _scrollToBottomStabilized(retries: retries - 1);
      });
    });
  }

  void _maybeAutoScrollToBottom(int messageCount) {
    // Only auto-scroll when new messages are appended.
    if (messageCount <= _lastRenderedMessageCount) {
      _lastRenderedMessageCount = messageCount;
      return;
    }
    _lastRenderedMessageCount = messageCount;
    if (_autoScrollScheduled) return;
    _autoScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollScheduled = false;
      _scrollToBottomStabilized();
    });
  }

  String _generateClientMessageId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  Future<List<Map<String, dynamic>>> _loadPersistedPendingMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingMessagesPrefsKey);
    if (raw == null || raw.trim().isEmpty) return <Map<String, dynamic>>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _savePersistedPendingMessages(
    List<Map<String, dynamic>> pendingMessages,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (pendingMessages.isEmpty) {
      await prefs.remove(_pendingMessagesPrefsKey);
      return;
    }
    await prefs.setString(
      _pendingMessagesPrefsKey,
      jsonEncode(pendingMessages),
    );
  }

  Future<void> _storePendingMessage(Map<String, dynamic> message) async {
    final pendingMessages = await _loadPersistedPendingMessages();
    pendingMessages.removeWhere(
      (item) =>
          (item['id'] ?? '').toString() == (message['id'] ?? '').toString(),
    );
    pendingMessages.add({
      'id': (message['id'] ?? '').toString(),
      'sender_id': (message['sender_id'] ?? '').toString(),
      'receiver_id': (message['receiver_id'] ?? '').toString(),
      'message': (message['message'] ?? '').toString(),
      'created_at': (message['created_at'] ?? '').toString(),
      'read': message['read'] == true,
      '_pending': true,
    });
    await _savePersistedPendingMessages(pendingMessages);
  }

  Future<void> _removePendingMessage(String messageId) async {
    if (messageId.isEmpty) return;
    final pendingMessages = await _loadPersistedPendingMessages();
    pendingMessages.removeWhere(
      (item) => (item['id'] ?? '').toString() == messageId,
    );
    await _savePersistedPendingMessages(pendingMessages);
  }

  Future<List<Map<String, dynamic>>> _pendingMessagesForCurrentThread() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return const [];

    final pendingMessages = await _loadPersistedPendingMessages();
    return pendingMessages
        .where((item) {
          final sender = (item['sender_id'] ?? '').toString();
          final receiver = (item['receiver_id'] ?? '').toString();
          return sender == userId && receiver == widget.friendId;
        })
        .map((item) {
          return {...item, 'read': item['read'] == true, '_pending': true};
        })
        .toList();
  }

  List<Map<String, dynamic>> _mergeThreadMessages(
    List<Map<String, dynamic>> sourceMessages,
    List<Map<String, dynamic>> pendingMessages,
  ) {
    final merged = <String, Map<String, dynamic>>{
      for (final message in sourceMessages)
        (message['id'] ?? '').toString(): Map<String, dynamic>.from(message),
    };

    for (final pending in pendingMessages) {
      final id = (pending['id'] ?? '').toString();
      if (id.isEmpty || merged.containsKey(id)) continue;
      merged[id] = Map<String, dynamic>.from(pending);
    }

    final result = merged.values.toList();
    result.sort(
      (a, b) => (a['created_at'] ?? '').toString().compareTo(
        (b['created_at'] ?? '').toString(),
      ),
    );
    return result;
  }

  Future<Map<String, dynamic>?> _fetchMessageById(String messageId) async {
    if (messageId.isEmpty) return null;
    final client = Supabase.instance.client;
    try {
      final row = await client
          .from('messages')
          .select()
          .eq('id', messageId)
          .maybeSingle();
      return row == null ? null : Map<String, dynamic>.from(row);
    } catch (_) {
      return null;
    }
  }

  Future<void> _replaceLocalMessage(
    String messageId,
    Map<String, dynamic> replacement,
  ) async {
    if (!mounted) return;
    setState(() {
      final next = List<Map<String, dynamic>>.from(_messages);
      final index = next.indexWhere(
        (message) => (message['id'] ?? '').toString() == messageId,
      );
      final normalizedReplacement = {
        ...Map<String, dynamic>.from(replacement),
        '_pending': false,
      };
      if (index == -1) {
        next.add(normalizedReplacement);
      } else {
        next[index] = {...next[index], ...normalizedReplacement};
      }
      next.sort(
        (a, b) => (a['created_at'] ?? '').toString().compareTo(
          (b['created_at'] ?? '').toString(),
        ),
      );
      _messages = next;
    });
  }

  Future<bool> _deliverPendingMessage(
    Map<String, dynamic> pendingMessage, {
    bool showFailureFeedback = true,
  }) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return false;

    final messageId = (pendingMessage['id'] ?? '').toString();
    if (messageId.isEmpty || _pendingDeliveryIds.contains(messageId)) {
      return false;
    }

    _pendingDeliveryIds.add(messageId);
    try {
      final inserted = await client
          .from('messages')
          .insert({
            'id': messageId,
            'sender_id': userId,
            'receiver_id': widget.friendId,
            'message': (pendingMessage['message'] ?? '').toString(),
            'created_at': (pendingMessage['created_at'] ?? '').toString(),
            'read': false,
          })
          .select()
          .single();

      await _removePendingMessage(messageId);
      await _replaceLocalMessage(
        messageId,
        Map<String, dynamic>.from(inserted),
      );
      return true;
    } catch (_) {
      final existing = await _fetchMessageById(messageId);
      if (existing != null) {
        await _removePendingMessage(messageId);
        await _replaceLocalMessage(messageId, existing);
        return true;
      }

      if (showFailureFeedback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Nachricht noch nicht synchronisiert. Wir versuchen es erneut.',
                'Message not synced yet. We will retry.',
              ),
            ),
          ),
        );
      }
      return false;
    } finally {
      _pendingDeliveryIds.remove(messageId);
    }
  }

  Future<void> _retryPendingMessagesForCurrentThread() async {
    final pendingMessages = await _pendingMessagesForCurrentThread();
    for (final pendingMessage in pendingMessages) {
      await _deliverPendingMessage(pendingMessage, showFailureFeedback: false);
    }
  }

  Future<void> _markMessagesAsRead() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    try {
      await client.rpc(
        'mark_messages_as_read',
        params: {'p_receiver_id': userId, 'p_sender_id': widget.friendId},
      );
    } catch (e) {
      // Only the RPC may change read/delivered state (see guard trigger).
      AppLogger.debug('mark_messages_as_read failed: $e');
    }
  }

  Future<void> _loadInitialMessages() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    if (mounted) {
      setState(() {
        _loadingMessages = true;
      });
    }

    try {
      final rawMessages = await client
          .from("messages")
          .select()
          .or(
            "and(sender_id.eq.$userId,receiver_id.eq.${widget.friendId}),and(sender_id.eq.${widget.friendId},receiver_id.eq.$userId)",
          )
          .order("created_at", ascending: false)
          .limit(100);

      final messages = List<Map<String, dynamic>>.from(rawMessages as List)
        ..sort(
          (a, b) => (a['created_at'] ?? '').toString().compareTo(
            (b['created_at'] ?? '').toString(),
          ),
        );
      var friendAvatarUrl = _friendAvatarUrl;
      final nextMessageReactions = <String, List<Map<String, dynamic>>>{};

      try {
        final profiles = await client
            .from("users_profile")
            .select("id, profile_picture")
            .inFilter("id", [userId, widget.friendId]);

        friendAvatarUrl = profiles.firstWhere(
          (p) => p['id'] == widget.friendId,
          orElse: () => {'profile_picture': null},
        )['profile_picture'];
      } catch (_) {
        // Profile metadata should never blank the chat thread.
      }

      try {
        final messageIds = messages
            .map((message) => message['id'])
            .where((messageId) => messageId != null)
            .toList();
        final reactions = messageIds.isNotEmpty
            ? await client
                  .from("message_reactions")
                  .select()
                  .inFilter("message_id", messageIds)
            : const [];

        for (final reaction in reactions) {
          final msgId = (reaction['message_id'] ?? '').toString();
          if (msgId.isEmpty) continue;
          nextMessageReactions
              .putIfAbsent(msgId, () => [])
              .add(Map<String, dynamic>.from(reaction));
        }
      } catch (_) {
        // Reactions are optional. Messages should remain visible without them.
      }

      final mergedMessages = _mergeThreadMessages(
        messages,
        await _pendingMessagesForCurrentThread(),
      );

      if (!mounted) return;
      setState(() {
        _friendAvatarUrl = friendAvatarUrl;
        _messageReactions
          ..clear()
          ..addAll(nextMessageReactions);
        _messages = mergedMessages;
        _lastRenderedMessageCount = mergedMessages.length;
        _loadingMessages = false;
      });
      unawaited(_retryPendingMessagesForCurrentThread());
    } catch (_) {
      final pendingMessages = await _pendingMessagesForCurrentThread();
      if (!mounted) return;
      setState(() {
        if (_messages.isEmpty || pendingMessages.isNotEmpty) {
          _messages = _mergeThreadMessages(_messages, pendingMessages);
        }
        _loadingMessages = false;
      });
      unawaited(_retryPendingMessagesForCurrentThread());
    }
  }

  void _setupChatRealtime() {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    _messagesSubscription?.unsubscribe();
    _messagesSubscription = client
        .channel('chat_messages_${userId}_${widget.friendId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: userId,
          ),
          callback: _handleMessageChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: widget.friendId,
          ),
          callback: _handleMessageChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: userId,
          ),
          callback: _handleMessageChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: widget.friendId,
          ),
          callback: _handleMessageChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: userId,
          ),
          callback: _handleMessageChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'sender_id',
            value: widget.friendId,
          ),
          callback: _handleMessageChange,
        )
        .subscribe();

    _reactionsSubscription?.unsubscribe();
    _reactionsSubscription = client
        .channel('chat_reactions_${userId}_${widget.friendId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'message_reactions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: _handleReactionChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'message_reactions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: widget.friendId,
          ),
          callback: _handleReactionChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'message_reactions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: _handleReactionChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'message_reactions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: widget.friendId,
          ),
          callback: _handleReactionChange,
        )
        .subscribe();
  }

  bool _isMessageInThisThread(Map record) {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) return false;
    final sender = (record['sender_id'] ?? '').toString();
    final receiver = (record['receiver_id'] ?? '').toString();
    return (sender == userId && receiver == widget.friendId) ||
        (sender == widget.friendId && receiver == userId);
  }

  void _handleMessageChange(dynamic payload) {
    if (!mounted) return;
    final newRecord = payload?.newRecord;
    final oldRecord = payload?.oldRecord;
    final record = (newRecord is Map)
        ? newRecord
        : (oldRecord is Map)
        ? oldRecord
        : null;
    if (record == null) return;
    if (!_isMessageInThisThread(record)) return;

    final msgId = (record['id'] ?? '').toString();
    if (msgId.isEmpty) return;

    final eventType = payload?.eventType;
    final isDelete =
        eventType == PostgresChangeEvent.delete ||
        (eventType?.toString().toLowerCase().contains('delete') ?? false);
    final wasNearBottom = _isNearBottom();
    final sender = (record['sender_id'] ?? '').toString();
    final receiver = (record['receiver_id'] ?? '').toString();

    setState(() {
      final idx = _messages.indexWhere(
        (m) => (m['id'] ?? '').toString() == msgId,
      );

      if (isDelete) {
        if (idx != -1) {
          final next = List<Map<String, dynamic>>.from(_messages);
          next.removeAt(idx);
          _messages = next;
          _messageReactions.remove(msgId);
        }
        return;
      }

      if (idx == -1) {
        final entry = {...Map<String, dynamic>.from(record), '_pending': false};
        final ts = (entry['created_at'] ?? '').toString();
        // Most realtime messages are the newest — fast-path append.
        if (_messages.isEmpty ||
            ts.compareTo((_messages.last['created_at'] ?? '').toString()) >=
                0) {
          _messages = [..._messages, entry];
        } else {
          // Rare out-of-order arrival: insert at sorted position.
          final next = List<Map<String, dynamic>>.from(_messages)..add(entry);
          next.sort(
            (a, b) => (a['created_at'] ?? '').toString().compareTo(
              (b['created_at'] ?? '').toString(),
            ),
          );
          _messages = next;
        }
        _freshMessageIds.add(msgId);
        Future.delayed(const Duration(milliseconds: 420), () {
          if (!mounted) return;
          if (_freshMessageIds.remove(msgId)) setState(() {});
        });
      } else {
        final next = List<Map<String, dynamic>>.from(_messages);
        next[idx] = {
          ...next[idx],
          ...Map<String, dynamic>.from(record),
          '_pending': false,
        };
        _messages = next;
      }
    });

    unawaited(_removePendingMessage(msgId));

    if (!isDelete && sender == widget.friendId && receiver == _currentUserId) {
      unawaited(_markMessagesAsRead());
    }

    if (wasNearBottom) {
      _maybeAutoScrollToBottom(_messages.length);
    }
  }

  void _handleReactionChange(dynamic payload) {
    final newRecord = payload?.newRecord;
    final oldRecord = payload?.oldRecord;
    final record = (newRecord is Map)
        ? newRecord
        : (oldRecord is Map)
        ? oldRecord
        : null;
    if (record == null) return;

    final msgId = (record['message_id'] ?? '').toString();
    if (msgId.isEmpty) return;
    final known = _messages.any((m) => (m['id'] ?? '').toString() == msgId);
    if (!known) return;

    final reactingUserId = (record['user_id'] ?? '').toString();
    if (reactingUserId.isEmpty) return;

    final guardKey = '$msgId|$reactingUserId';
    if (_localReactionWriteGuards.contains(guardKey)) return;

    final eventType = payload?.eventType;
    final isDelete =
        eventType == PostgresChangeEvent.delete ||
        (eventType?.toString().toLowerCase().contains('delete') ?? false);
    final emoji = (record['emoji'] ?? '').toString();
    if (!isDelete && emoji.isEmpty) return;

    setState(() {
      final next = List<Map<String, dynamic>>.from(
        _messageReactions[msgId] ?? const <Map<String, dynamic>>[],
      );
      next.removeWhere(
        (r) => (r['user_id'] ?? '').toString() == reactingUserId,
      );

      if (!isDelete) {
        next.add({
          'message_id': msgId,
          'user_id': reactingUserId,
          'emoji': emoji,
        });
        _bumpReactionAnim(msgId, emoji);
      }

      if (next.isEmpty) {
        _messageReactions.remove(msgId);
      } else {
        _messageReactions[msgId] = next;
      }
    });
  }

  Future<void> _refreshReactionsForMessage(String messageId) async {
    final client = Supabase.instance.client;
    try {
      final reactions = await client
          .from('message_reactions')
          .select('message_id, user_id, emoji')
          .eq('message_id', messageId);
      if (!mounted) return;
      setState(() {
        _messageReactions[messageId] = List<Map<String, dynamic>>.from(
          reactions as List,
        );
      });
    } catch (_) {
      // ignore
    }
  }

  Future<List<Map<String, dynamic>>> loadMessages() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser!.id;

    try {
      final messages = await client
          .from("messages")
          .select()
          .or(
            "and(sender_id.eq.$userId,receiver_id.eq.${widget.friendId}),and(sender_id.eq.${widget.friendId},receiver_id.eq.$userId)",
          )
          .order("created_at", ascending: false)
          .limit(100);
      final rows = List<Map<String, dynamic>>.from(messages as List)
        ..sort(
          (a, b) => (a['created_at'] ?? '').toString().compareTo(
            (b['created_at'] ?? '').toString(),
          ),
        );
      Map<String, dynamic>? Function(Map<String, dynamic>) profileForMessage =
          (_) => null;
      final nextMessageReactions = <String, List<Map<String, dynamic>>>{};

      try {
        final profiles = await client
            .from("users_profile")
            .select("id, profile_picture")
            .inFilter("id", [userId, widget.friendId]);
        final profileMap = {
          for (final profile in profiles)
            (profile['id'] ?? '').toString(): Map<String, dynamic>.from(
              profile,
            ),
        };
        profileForMessage = (message) {
          return profileMap[(message['sender_id'] ?? '').toString()];
        };
      } catch (_) {
        // Profile pictures are optional. Keep rendering the messages without them.
      }

      try {
        final messageIds = rows
            .map((message) => message['id'])
            .where((messageId) => messageId != null)
            .toList();
        final reactions = messageIds.isNotEmpty
            ? await client
                  .from("message_reactions")
                  .select()
                  .inFilter("message_id", messageIds)
            : const [];

        for (final reaction in reactions) {
          final msgId = (reaction['message_id'] ?? '').toString();
          if (msgId.isEmpty) continue;
          nextMessageReactions
              .putIfAbsent(msgId, () => [])
              .add(Map<String, dynamic>.from(reaction));
        }
      } catch (_) {
        // Reaction fetch failures should never erase the thread.
      }

      _messageReactions
        ..clear()
        ..addAll(nextMessageReactions);

      return rows.map<Map<String, dynamic>>((msg) {
        final profile = profileForMessage(msg);
        return {...msg, 'sender_profile_picture': profile?['profile_picture']};
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> addReaction(String messageId, String emoji) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    try {
      // WhatsApp-like behavior: one reaction per user per message.
      // - Tap same emoji again: remove reaction.
      // - Tap different emoji: replace existing reaction.

      // Optimistic local update first (keeps UI instant + guarantees animation).
      final list = _messageReactions.putIfAbsent(messageId, () => []);
      final guardKey = '$messageId|$userId';
      _localReactionWriteGuards.add(guardKey);
      Future.delayed(const Duration(milliseconds: 900), () {
        _localReactionWriteGuards.remove(guardKey);
      });
      final alreadyReactedWithThisEmoji = list.any(
        (r) => r['user_id'] == userId && r['emoji'] == emoji,
      );

      // Remove all current-user reactions for this message.
      list.removeWhere((r) => r['user_id'] == userId);

      // Re-add only if this is not an "unreact".
      if (!alreadyReactedWithThisEmoji) {
        list.add({'message_id': messageId, 'user_id': userId, 'emoji': emoji});
      }

      if (list.isEmpty) {
        _messageReactions.remove(messageId);
      }

      _bumpReactionAnim(messageId, emoji);
      if (mounted) setState(() {});

      await client
          .from('message_reactions')
          .delete()
          .eq('message_id', messageId)
          .eq('user_id', userId);

      if (alreadyReactedWithThisEmoji) return;

      await client.from('message_reactions').insert({
        'message_id': messageId,
        'user_id': userId,
        'emoji': emoji,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t("Fehler bei Reaktion", "Reaction error"))),
        );

        // Best-effort resync for this message.
        _refreshReactionsForMessage(messageId);
      }
    }
  }

  Future<void> sendMessage() async {
    final text = messageCtrl.text.trim();
    if (text.isEmpty) return;
    await _sendMessagePayload(text, triggerHaptic: true);
  }

  Future<ImageSource?> _pickChatImageSource() async {
    if (!mounted) return null;
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
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

  Future<void> _sendImageMessage() async {
    if (sending) return;

    final source = await _pickChatImageSource();
    if (source == null) return;

    XFile? file;
    try {
      file = await _chatImagePicker.pickImage(
        source: source,
        imageQuality: 88,
        maxWidth: 1920,
        maxHeight: 1920,
      );
    } on PlatformException catch (e) {
      if (mounted) {
        final msg = isImagePickerAccessDenied(e)
            ? imagePickerAccessDeniedMessage(
                cameraOnly: source == ImageSource.camera,
              )
            : t(
                'Foto konnte nicht geöffnet werden (${e.code}).',
                'Could not open photo (${e.code}).',
              );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
      return;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('Fehler beim \u00d6ffnen des Fotos', 'Error opening photo'),
            ),
          ),
        );
      }
      return;
    }

    if (file == null) return;

    // Validate image before upload (size + MIME type)
    final imgValidation = await validateImageFile(file.path);
    if (!imgValidation.isValid) {
      if (mounted) {
        final msg = imgValidation.error == ImageValidationError.tooLarge
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

    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    setState(() => sending = true);
    try {
      final fileName = 'chat_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storagePath = '$userId/$fileName';
      final compressedChatFile = await compressPhotoForUpload(file.path);
      await client.storage
          .from('photos')
          .upload(storagePath, compressedChatFile);
      final publicUrl = client.storage.from('photos').getPublicUrl(storagePath);

      final caption = messageCtrl.text.trim();
      final payload = caption.isEmpty ? publicUrl : '$caption\n$publicUrl';
      await _sendMessagePayload(payload, manageSending: false);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('Fehler beim Senden des Fotos', 'Error sending photo'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => sending = false);
      }
    }
  }

  Future<void> _sendMessagePayload(
    String text, {
    bool manageSending = true,
    bool triggerHaptic = false,
  }) async {
    final userId =
        _currentUserId ?? Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    final payload = text.trim();
    if (payload.isEmpty) return;

    if (triggerHaptic) {
      HapticFeedback.selectionClick();
    }
    messageCtrl.clear();
    _canSend.value = false;

    if (manageSending && mounted) {
      setState(() => sending = true);
    }

    final createdAt = DateTime.now().toUtc().toIso8601String();
    final optimisticId = _generateClientMessageId();
    final optimistic = <String, dynamic>{
      'id': optimisticId,
      'sender_id': userId,
      'receiver_id': widget.friendId,
      'message': payload,
      'created_at': createdAt,
      'read': true,
      '_pending': true,
    };

    await _storePendingMessage(optimistic);

    // The chat may have been closed meanwhile; the stored message is still
    // delivered below (and retried on the next open if that fails).
    if (mounted) {
      setState(() {
        final next = List<Map<String, dynamic>>.from(_messages)
          ..add(optimistic);
        next.sort(
          (a, b) => (a['created_at'] ?? '').toString().compareTo(
            (b['created_at'] ?? '').toString(),
          ),
        );
        _messages = next;
        _freshMessageIds.add(optimisticId);
      });
      Future.delayed(const Duration(milliseconds: 420), () {
        if (!mounted) return;
        if (_freshMessageIds.remove(optimisticId)) setState(() {});
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }

    await _deliverPendingMessage(optimistic);

    if (manageSending && mounted) {
      setState(() => sending = false);
    }
  }

  Future<void> deleteMessage(String messageId) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;
    if (messageId.isEmpty) return;

    try {
      final existingMessage = await client
          .from("messages")
          .select("id, sender_id")
          .eq("id", messageId)
          .maybeSingle();

      if (existingMessage == null) {
        final localPending = _messages.any(
          (message) =>
              (message['id'] ?? '').toString() == messageId &&
              message['_pending'] == true,
        );
        if (localPending) {
          await _removePendingMessage(messageId);
          if (!mounted) return;
          setState(() {
            final next = List<Map<String, dynamic>>.from(_messages);
            next.removeWhere((m) => (m['id'] ?? '').toString() == messageId);
            _messages = next;
          });
          return;
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(t('Nachricht nicht gefunden', 'Message not found')),
            ),
          );
        }
        return;
      }

      if (existingMessage['sender_id'] != userId) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Du kannst nur deine Nachrichten l\u00f6schen',
                  'You can only delete your own messages',
                ),
              ),
            ),
          );
        }
        return;
      }

      await client.from("messages").delete().eq("id", messageId);

      if (mounted) {
        setState(() {
          _deletingMessageIds.remove(messageId);
          final next = List<Map<String, dynamic>>.from(_messages);
          next.removeWhere((m) => (m['id'] ?? '').toString() == messageId);
          _messages = next;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('Nachricht gel\u00f6scht', 'Message deleted')),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _deletingMessageIds.remove(messageId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ErrorMapper.describe(
                e,
                whatDe: 'Fehler beim L\u00f6schen',
                whatEn: 'Error deleting',
              ),
            ),
          ),
        );
      }
    }
  }

  Map<String, dynamic>? _messageById(String messageId) {
    for (final message in _messages) {
      if ((message['id'] ?? '').toString() == messageId) {
        return Map<String, dynamic>.from(message);
      }
    }
    return null;
  }

  Future<void> _showMessageReportedDialog({
    required bool alreadyReported,
  }) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: const Color(0xFF1E1E1E),
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alreadyReported
                      ? t('Bereits gemeldet', 'Already reported')
                      : t('Nachricht gemeldet', 'Message reported'),
                  style: _inter.copyWith(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  alreadyReported
                      ? t(
                          'Diese Nachricht wurde bereits gemeldet. Die letzten 5 Nachrichten liegen SideQuest schon zur Überprüfung vor.',
                          'This message was already reported. The last 5 messages are already with SideQuest for review.',
                        )
                      : t(
                          'Die letzten 5 Nachrichten wurden zur Überprüfung an SideQuest weitergeleitet.',
                          'The last 5 messages were forwarded to SideQuest for review.',
                        ),
                  style: _inter.copyWith(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: appGreen,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    child: Text(
                      t('OK', 'OK'),
                      style: _inter.copyWith(fontWeight: FontWeight.w700),
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

  Future<bool> _confirmMessageReport() async {
    if (!mounted) return false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          t('Nachricht melden?', 'Report message?'),
          style: _inter.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          t(
            'Wenn du diese Nachricht meldest, werden die letzten 5 Nachrichten zur Überprüfung an SideQuest gesendet.',
            'If you report this message the last 5 messages will be sent to SideQuest for review.',
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
              t('Melden', 'Report'),
              style: _inter.copyWith(
                color: Colors.orangeAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  Future<void> _reportIncomingMessage(String messageId) async {
    if (_messageById(messageId) == null) return;
    final confirmed = await _confirmMessageReport();
    if (!confirmed) return;

    try {
      final result = await MessageReportService.submitConversationReport(
        client: Supabase.instance.client,
        messageId: messageId,
        otherUserId: widget.friendId,
      );
      await _showMessageReportedDialog(
        alreadyReported:
            result == MessageReportSubmissionResult.alreadyReported,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Melden der Nachricht fehlgeschlagen',
              'Reporting the message failed',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _showIncomingMessageActions(String messageId) async {
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.flag_outlined,
                  color: Colors.orangeAccent,
                ),
                title: Text(
                  t('Nachricht melden', 'Report message'),
                  style: _inter.copyWith(color: Colors.white),
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _reportIncomingMessage(messageId);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _removeFriendFromChat() async {
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
            'Der Chat bleibt erhalten, aber ihr seid nicht mehr befreundet.',
            'The chat will remain, but you will no longer be friends.',
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
          .from("friends")
          .delete()
          .or(
            "and(user_id.eq.$userId,friend_id.eq.${widget.friendId}),and(user_id.eq.${widget.friendId},friend_id.eq.$userId)",
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
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

  Future<void> _blockUserFromChat() async {
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
      await BlockService.blockUser(widget.friendId);
      FriendDiscoveryService.invalidateSuggestionsForCurrentUser();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Nutzer blockiert', 'User blocked'))),
      );
      Navigator.of(context).pop(true);
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

  void _showReactionMenu(
    BuildContext context,
    String messageId,
    bool isOwn,
    Offset tapPosition, {
    Rect? messageRect,
    double leftShift = 0.0,
  }) {
    _dismissReactionOverlay();
    _setPressedMessage(messageId);
    HapticFeedback.lightImpact();

    final overlayState = Overlay.of(context);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;

    const horizontalPadding = 12.0;
    const barHeight = 56.0;
    final maxBarWidth = overlaySize.width - (horizontalPadding * 2);
    // No more guessed `barWidth`. The bar shrink-wraps to whatever the Row
    // actually measures at runtime — this is what kept producing a visible
    // empty strip on the right side because emoji glyph widths differ per
    // platform/font. Positioning uses left-anchor (incoming messages) or
    // right-anchor (own messages) so we never need to know the width.

    double? barLeft;
    double? barRight;
    double top;

    if (messageRect != null) {
      if (isOwn) {
        // Anchor the bar's right edge to the message's right edge. `leftShift`
        // nudges the whole bar left, which in right-anchored terms is the
        // same as increasing distance-from-right.
        final rightInset =
            (overlaySize.width - messageRect.right) - leftShift;
        barRight = rightInset.clamp(
          horizontalPadding,
          overlaySize.width - horizontalPadding,
        );
      } else {
        barLeft = (messageRect.left + leftShift).clamp(
          horizontalPadding,
          overlaySize.width - horizontalPadding,
        );
      }

      top = messageRect.top - barHeight - 18;
      if (top < 18) {
        top = messageRect.bottom + 10;
      }
      top = top.clamp(18.0, overlaySize.height - barHeight - 18.0);
    } else {
      // Tap-position floating case — we still don't know the exact width, so
      // estimate conservatively for centering. Slight off-center is fine; the
      // important visual case (anchored to a message bubble) uses left/right.
      final estimatedWidth =
          ((_reactionEmojis.length * 46) + 70).toDouble().clamp(
            0.0,
            maxBarWidth,
          );
      barLeft = (tapPosition.dx - estimatedWidth / 2 + leftShift).clamp(
        horizontalPadding,
        overlaySize.width - estimatedWidth - horizontalPadding,
      );

      top = tapPosition.dy - 96;
      if (top < 18) {
        top = tapPosition.dy + 12;
      }
      top = top.clamp(18.0, overlaySize.height - barHeight - 18.0);
    }

    int? hoveredIndex;

    // WhatsApp-style: highlight the emoji the current user has already
    // reacted with so they can see (and toggle off) their selection.
    String? myCurrentReaction;
    final myUserId = _currentUserId;
    if (myUserId != null) {
      for (final r in _messageReactions[messageId] ?? const []) {
        if (r['user_id'] == myUserId) {
          myCurrentReaction = (r['emoji'] ?? '').toString();
          if (myCurrentReaction.isEmpty) myCurrentReaction = null;
          break;
        }
      }
    }

    double intervalT(double t, double start, double end) {
      if (t <= start) return 0.0;
      if (t >= end) return 1.0;
      return ((t - start) / (end - start)).clamp(0.0, 1.0);
    }

    Widget emojiChip(
      void Function(void Function()) setOverlayState,
      String emoji,
      int index,
      double openT,
      Animation<double> openAnimation,
    ) {
      final hovered = hoveredIndex == index;
      final isSelected = myCurrentReaction == emoji;

      // Gestaffeltes Erscheinen pro Emoji
      final appearT = Curves.easeOutBack.transform(
        intervalT(openT, 0.02 + (index * 0.035), 0.58),
      );
      // Same values as easeOut(intervalT(openT, index * 0.03, 0.42)), applied
      // as a layer fade instead of repainting the chip every frame.
      final appearOpacity = openAnimation.drive(
        CurveTween(
          curve: Interval(0.0 + (index * 0.03), 0.42, curve: Curves.easeOut),
        ),
      );

      Widget content = Text(
        emoji,
        style: TextStyle(
          fontSize: 26,
          color: emoji == _emojiHeart ? Colors.red : Colors.white,
        ),
      );

      // Selected state has priority over hover for the visual treatment.
      final Color bgColor = isSelected
          ? appGreen.withValues(alpha: 0.28)
          : hovered
          ? Colors.white.withValues(alpha: 0.22)
          : Colors.transparent;
      final Color borderColor = isSelected
          ? appGreen.withValues(alpha: 0.7)
          : hovered
          ? Colors.white.withValues(alpha: 0.14)
          : Colors.transparent;
      final double idleScale = isSelected ? 1.08 : 1.0;

      return FadeTransition(
        opacity: appearOpacity,
        child: Transform.scale(
          scale: 0.82 + (0.18 * appearT),
          child: GestureDetector(
            onTapDown: (_) {
              setOverlayState(() {
                hoveredIndex = index;
              });
              HapticFeedback.selectionClick();
            },
            onTapUp: (_) {
              setOverlayState(() {
                hoveredIndex = null;
              });
            },
            onTapCancel: () {
              setOverlayState(() {
                hoveredIndex = null;
              });
            },
            onTap: () {
              HapticFeedback.lightImpact();
              _dismissReactionOverlay();
              addReaction(messageId, emoji);
            },
            child: AnimatedScale(
              scale: hovered ? 1.18 : idleScale,
              duration: const Duration(milliseconds: 110),
              curve: Curves.easeOutBack,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: bgColor,
                  border: Border.all(
                    color: borderColor,
                    width: isSelected ? 1.4 : 1,
                  ),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: content,
              ),
            ),
          ),
        ),
      );
    }

    _reactionOverlayEntry = OverlayEntry(
      builder: (overlayContext) {
        return Positioned.fill(
          child: Material(
            color: Colors.black.withValues(alpha: 0.08),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismissReactionOverlay,
              child: StatefulBuilder(
                builder: (context, setOverlayState) {
                  return Stack(
                    children: [
                      Positioned(
                        left: barLeft,
                        right: barRight,
                        top: top,
                        child: _OneShotAnimationBuilder(
                          duration: const Duration(milliseconds: 210),
                          curve: Curves.easeOutCubic,
                          builder: (context, animation) {
                            final animT = animation.value;
                            final revealT = Curves.easeOutCubic.transform(
                              animT,
                            );
                            final popT = Curves.easeOutBack.transform(
                              intervalT(animT, 0.0, 0.72),
                            );
                            final popTClamped = popT.clamp(0.0, 1.0);

                            Widget bar = Container(
                              // Cap-only constraint so the bar shrink-wraps
                              // to its real Row width and never leaves a
                              // visible empty strip on either side.
                              constraints: BoxConstraints(
                                maxWidth: maxBarWidth,
                              ),
                              height: barHeight,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2A2D28),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (
                                      int i = 0;
                                      i < _reactionEmojis.length;
                                      i++
                                    )
                                      emojiChip(
                                        setOverlayState,
                                        _reactionEmojis[i],
                                        i,
                                        animT,
                                        animation,
                                      ),
                                    if (isOwn) ...[
                                      Container(
                                        width: 1,
                                        height: 26,
                                        color: Colors.grey.shade600,
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () async {
                                          _dismissReactionOverlay();
                                          final confirm = await showDialog<bool>(
                                            context: context,
                                            builder: (dialCtx) => AlertDialog(
                                              backgroundColor:
                                                  Colors.grey.shade900,
                                              title: Text(
                                                t(
                                                  'Nachricht l\u00f6schen?',
                                                  'Delete message?',
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                              content: Text(
                                                t(
                                                  'Diese Nachricht wird entfernt.',
                                                  'This message will be removed.',
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                ),
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                        dialCtx,
                                                        false,
                                                      ),
                                                  child: Text(
                                                    t('Abbrechen', 'Cancel'),
                                                    style: const TextStyle(
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                                ),
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                        dialCtx,
                                                        true,
                                                      ),
                                                  child: Text(
                                                    t('L\u00f6schen', 'Delete'),
                                                    style: const TextStyle(
                                                      color: Colors.red,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                          if (confirm == true && mounted) {
                                            setState(
                                              () => _deletingMessageIds.add(
                                                messageId,
                                              ),
                                            );
                                            await Future.delayed(
                                              const Duration(milliseconds: 300),
                                            );
                                            await deleteMessage(messageId);
                                          }
                                        },
                                        child: const Icon(
                                          Icons.delete_outline,
                                          color: Colors.red,
                                          size: 24,
                                        ),
                                      ),
                                    ] else ...[
                                      Container(
                                        width: 1,
                                        height: 26,
                                        color: Colors.grey.shade600,
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () async {
                                          _dismissReactionOverlay();
                                          await _showIncomingMessageActions(
                                            messageId,
                                          );
                                        },
                                        child: const Icon(
                                          Icons.more_horiz,
                                          color: Colors.white,
                                          size: 24,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );

                            bar = Transform.scale(
                              scale: 0.96 + (0.04 * popTClamped),
                              alignment: Alignment.centerLeft,
                              // Same values as 0.25 + 0.75 * revealT (always
                              // within 0..1), applied as a layer fade.
                              child: FadeTransition(
                                opacity: animation.drive(
                                  Tween<double>(begin: 0.25, end: 1.0).chain(
                                    CurveTween(curve: Curves.easeOutCubic),
                                  ),
                                ),
                                child: ClipRect(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: revealT,
                                    child: bar,
                                  ),
                                ),
                              ),
                            );

                            return Transform.translate(
                              offset: Offset(0, (1 - revealT) * 32),
                              child: bar,
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );

    overlayState.insert(_reactionOverlayEntry!);
  }

  void _openFriendProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfileScreen(userId: widget.friendId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = Supabase.instance.client;
    final currentUserId = client.auth.currentUser?.id ?? '';
    final mediaQuery = MediaQuery.of(context);
    final safeBottom = mediaQuery.padding.bottom;

    // Instagram-style dark colors
    const darkBg = Color(0xFF121212);
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);

    return Scaffold(
      backgroundColor: darkBg,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: darkBg,
        iconTheme: const IconThemeData(color: Colors.white),
        title: GestureDetector(
          onTap: _openFriendProfile,
          child: Text(
            widget.friendUsername,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _inter.copyWith(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: textPrimary,
            ),
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            color: cardDark,
            tooltip: t('Optionen', 'Options'),
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) async {
              if (value == 'remove_friend') {
                await _removeFriendFromChat();
              } else if (value == 'block_user') {
                await _blockUserFromChat();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'remove_friend',
                child: Row(
                  children: [
                    const Icon(Icons.delete_outline, color: Color(0xFFFFB74D)),
                    const SizedBox(width: 10),
                    Text(
                      t('Freund entfernen', 'Remove friend'),
                      style: _inter.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'block_user',
                child: Row(
                  children: [
                    const Icon(Icons.block, color: Colors.redAccent),
                    const SizedBox(width: 10),
                    Text(
                      t('Blockieren', 'Block'),
                      style: _inter.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: Builder(
              builder: (context) {
                if (_loadingMessages) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (_messages.isEmpty) {
                  return Center(
                    child: Text(
                      t("Keine Nachrichten", "No messages"),
                      style: _inter.copyWith(
                        fontSize: 16,
                        color: textSecondary,
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  controller: scrollController,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                  itemCount: _messages.length,
                  // ignore: deprecated_member_use
                  cacheExtent: 1000,
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: true,
                  itemBuilder: (context, i) {
                    final msg = _messages[_messages.length - 1 - i];
                    final msgId = msg['id']?.toString() ?? '';
                    final isOwn = msg['sender_id'] == currentUserId;
                    final isPressed = _pressedMessageId == msgId;
                    final reactions = _messageReactions[msgId] ?? const [];
                    final messageText = (msg['message'] ?? '').toString();
                    final isFresh = _freshMessageIds.contains(msgId);
                    final isPending = msg['_pending'] == true;
                    // Only our own storage URLs are shown as images; other
                    // links stay plain text (no auto-loading of foreign URLs).
                    String? imageUrl;
                    if (messageText.contains('http')) {
                      final parts = messageText.split(RegExp(r"\s+"));
                      for (final part in parts) {
                        if (isTrustedSideQuestMediaUrl(part)) {
                          imageUrl = part;
                        }
                      }
                    }
                    final displayText = imageUrl == null
                        ? messageText.trim()
                        : messageText.replaceAll(imageUrl, '').trim();
                    final showText = displayText.isNotEmpty
                        ? displayText
                        : (imageUrl == null ? messageText : "");

                    // Compute counts ONCE per build (was 6× O(n²) before).
                    final reactionCounts = <String, int>{};
                    for (final r in reactions) {
                      final e = (r['emoji'] ?? '').toString();
                      if (e.isEmpty) continue;
                      reactionCounts[e] = (reactionCounts[e] ?? 0) + 1;
                    }
                    final orderedActiveEmojis = _reactionEmojis
                        .where((e) => (reactionCounts[e] ?? 0) > 0)
                        .toList(growable: false);

                    Widget buildReactionPill() {
                      if (orderedActiveEmojis.isEmpty) {
                        return const SizedBox.shrink();
                      }

                      // No more AnimatedSwitcher: each chip handles its own
                      // press + spring-pop. AnimatedSize smooths width changes
                      // when emojis are added/removed without "swap" jank.
                      return AnimatedSize(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.center,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade800,
                            borderRadius: BorderRadius.circular(999),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.14),
                                blurRadius: 10,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final emoji in orderedActiveEmojis)
                                _ReactionChip(
                                  key: ValueKey('chip_${msgId}_$emoji'),
                                  emoji: emoji,
                                  count: reactionCounts[emoji]!,
                                  isHeart: emoji == _emojiHeart,
                                  popTick:
                                      _reactionAnimTicks['$msgId|$emoji'] ?? 0,
                                  onTap: () => addReaction(msgId, emoji),
                                ),
                            ],
                          ),
                        ),
                      );
                    }

                    Widget item = Padding(
                      key: ValueKey('msg_$msgId'),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Align(
                        alignment: isOwn
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: isOwn
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: isOwn
                                  ? MainAxisAlignment.end
                                  : MainAxisAlignment.start,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (!isOwn)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: GestureDetector(
                                      onTap: _openFriendProfile,
                                      child: CircleAvatar(
                                        radius: 16,
                                        backgroundColor: Colors.black,
                                        backgroundImage:
                                            _friendAvatarUrl != null
                                            ? sideQuestCachedImageProvider(
                                                sideQuestThumbnailUrl(
                                                      _friendAvatarUrl!,
                                                      width: 96,
                                                      height: 96,
                                                      quality: 65,
                                                    ) ??
                                                    _friendAvatarUrl!,
                                                cacheWidth: sideQuestCacheWidth(
                                                  context,
                                                  32,
                                                ),
                                                cacheHeight:
                                                    sideQuestCacheWidth(
                                                      context,
                                                      32,
                                                    ),
                                              )
                                            : null,
                                        child: _friendAvatarUrl == null
                                            ? Text(
                                                (widget.friendUsername)[0]
                                                    .toUpperCase(),
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                ),
                                              )
                                            : null,
                                      ),
                                    ),
                                  ),
                                Flexible(
                                  fit: FlexFit.loose,
                                  child: Builder(
                                    builder: (bubbleCtx) {
                                      final bubbleMaxWidth =
                                          MediaQuery.sizeOf(bubbleCtx).width *
                                          0.74;
                                      return GestureDetector(
                                        onLongPressStart: (details) {
                                          final isChallengePhoto =
                                              showText.contains(
                                                'Challenge gewonnen! Foto',
                                              ) ||
                                              showText.contains(
                                                'Challenge won! Photo',
                                              );
                                          final leftShift = isChallengePhoto
                                              ? (isOwn ? 0.0 : -18.0)
                                              : 0.0;
                                          final obj = bubbleCtx
                                              .findRenderObject();
                                          if (obj is RenderBox) {
                                            final rect =
                                                obj.localToGlobal(Offset.zero) &
                                                obj.size;
                                            _showReactionMenu(
                                              context,
                                              msgId,
                                              isOwn,
                                              details.globalPosition,
                                              messageRect: rect,
                                              leftShift: leftShift,
                                            );
                                            return;
                                          }
                                          _showReactionMenu(
                                            context,
                                            msgId,
                                            isOwn,
                                            details.globalPosition,
                                            leftShift: leftShift,
                                          );
                                        },
                                        child: AnimatedOpacity(
                                          opacity:
                                              _deletingMessageIds.contains(
                                                msgId,
                                              )
                                              ? 0.0
                                              : 1.0,
                                          duration: const Duration(
                                            milliseconds: 300,
                                          ),
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(
                                              maxWidth: bubbleMaxWidth,
                                            ),
                                            child: RepaintBoundary(
                                              child: Stack(
                                                clipBehavior: Clip.none,
                                                alignment: isOwn
                                                    ? Alignment.centerRight
                                                    : Alignment.centerLeft,
                                                children: [
                                                  AnimatedContainer(
                                                      duration: const Duration(
                                                        milliseconds: 180,
                                                      ),
                                                      curve:
                                                          Curves.easeOutCubic,
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 14,
                                                            vertical: 10,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: isOwn
                                                            ? appGreen
                                                            : cardDark,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              16,
                                                            ),
                                                        border: isOwn
                                                            ? null
                                                            : Border.all(
                                                                color:
                                                                    isPressed
                                                                    ? appGreen
                                                                          .withValues(
                                                                            alpha:
                                                                                0.55,
                                                                          )
                                                                    : const Color(
                                                                        0xFF2A2A2A,
                                                                      ),
                                                                width: 1,
                                                              ),
                                                        boxShadow: [
                                                          BoxShadow(
                                                            color:
                                                                (isOwn
                                                                        ? appGreen
                                                                        : Colors
                                                                              .black)
                                                                    .withValues(
                                                                      alpha:
                                                                          isPressed
                                                                          ? 0.35
                                                                          : 0.15,
                                                                    ),
                                                            blurRadius:
                                                                isPressed
                                                                ? 18
                                                                : 4,
                                                            offset: Offset(
                                                              0,
                                                              isPressed
                                                                  ? 10
                                                                  : 2,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          if (showText
                                                              .isNotEmpty)
                                                            Text(
                                                              showText,
                                                              softWrap: true,
                                                              style: _inter.copyWith(
                                                                color: isOwn
                                                                    ? Colors
                                                                          .black
                                                                    : textPrimary,
                                                                fontSize: 14,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w400,
                                                              ),
                                                            ),
                                                          if (imageUrl !=
                                                              null) ...[
                                                            const SizedBox(
                                                              height: 8,
                                                            ),
                                                            ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    12,
                                                                  ),
                                                              child: sideQuestNetworkImage(
                                                                imageUrl:
                                                                    imageUrl,
                                                                width: 200,
                                                                height: 200,
                                                                fit: BoxFit
                                                                    .cover,
                                                                cacheWidth:
                                                                    sideQuestCacheWidth(
                                                                      context,
                                                                      200,
                                                                    ),
                                                                cacheHeight:
                                                                    sideQuestCacheWidth(
                                                                      context,
                                                                      200,
                                                                    ),
                                                                filterQuality:
                                                                    FilterQuality
                                                                        .low,
                                                              ),
                                                            ),
                                                          ],
                                                          const SizedBox(
                                                            height: 4,
                                                          ),
                                                          Row(
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              Text(
                                                                isPending
                                                                    ? t(
                                                                        'sendet...',
                                                                        'sending...',
                                                                      )
                                                                    : () {
                                                                        try {
                                                                          final localTime = DateTime.parse(
                                                                            msg['created_at']
                                                                                .toString(),
                                                                          ).toLocal();
                                                                          return '${localTime.hour.toString().padLeft(2, '0')}:${localTime.minute.toString().padLeft(2, '0')}';
                                                                        } catch (
                                                                          _
                                                                        ) {
                                                                          return msg['created_at']
                                                                              .toString()
                                                                              .substring(
                                                                                11,
                                                                                16,
                                                                              );
                                                                        }
                                                                      }(),
                                                                style: _inter.copyWith(
                                                                  fontSize: 11,
                                                                  color: isOwn
                                                                      ? Colors.black
                                                                      : Colors
                                                                            .grey
                                                                            .shade600,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w400,
                                                                ),
                                                              ),
                                                              if (isOwn) ...[
                                                                const SizedBox(width: 3),
                                                                MessageStatusTicks(
                                                                  status: messageDeliveryStatus(msg),
                                                                ),
                                                              ],
                                                            ],
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  if (reactions.isNotEmpty)
                                                    Positioned(
                                                      bottom: -23,
                                                      right: isOwn ? 8 : null,
                                                      left: isOwn ? null : 8,
                                                      child:
                                                          buildReactionPill(),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                if (isOwn) const SizedBox(width: 8),
                              ],
                            ),
                            // Reserve space for the reaction pill (drawn just
                            // outside the bubble). AnimatedContainer = no
                            // sudden layout jump when the first reaction lands.
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              height: reactions.isNotEmpty ? 24 : 0,
                            ),
                          ],
                        ),
                      ),
                    );

                    if (!isFresh) return item;
                    return FadeSlideIn(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      offsetY: 10,
                      child: item,
                    );
                  },
                );
              },
            ),
          ),
          AnimatedPadding(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            padding: EdgeInsets.fromLTRB(16, 10, 16, 10 + safeBottom),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: cardDark,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: const Color(0xFF2A2A2A),
                      width: 1,
                    ),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: sending ? null : _sendImageMessage,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          Icons.photo_camera_outlined,
                          color: sending ? Colors.white54 : Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: messageCtrl,
                    style: _inter.copyWith(color: textPrimary),
                    textInputAction: TextInputAction.send,
                    minLines: 1,
                    maxLines: 4,
                    onSubmitted: (_) {
                      if (!_canSend.value || sending) return;
                      sendMessage();
                    },
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: cardDark,
                      hintText: t("Nachricht...", "Message..."),
                      hintStyle: _inter.copyWith(color: textSecondary),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<bool>(
                  valueListenable: _canSend,
                  builder: (context, canSend, _) {
                    final enabled = canSend && !sending;
                    return AnimatedScale(
                      scale: enabled ? 1.0 : 0.98,
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        decoration: BoxDecoration(
                          color: enabled ? appGreen : const Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: enabled
                              ? [
                                  BoxShadow(
                                    color: appGreen.withValues(alpha: 0.25),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ]
                              : [],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: enabled ? sendMessage : null,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                switchInCurve: Curves.easeOut,
                                switchOutCurve: Curves.easeIn,
                                transitionBuilder: (child, anim) =>
                                    FadeTransition(
                                      opacity: anim,
                                      child: ScaleTransition(
                                        scale: anim,
                                        child: child,
                                      ),
                                    ),
                                child: sending
                                    ? SizedBox(
                                        key: const ValueKey('sending'),
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              const AlwaysStoppedAnimation<
                                                Color
                                              >(Colors.white),
                                        ),
                                      )
                                    : Icon(
                                        Icons.send_rounded,
                                        key: const ValueKey('send'),
                                        color: enabled
                                            ? Colors.white
                                            : Colors.white54,
                                        size: 21,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Runs [curve] from 0 to 1 once over [duration] when first built, exactly
/// like a `TweenAnimationBuilder<double>` with a 0 -> 1 tween, but passes the
/// [Animation] itself to [builder] so fades can use `FadeTransition`.
/// Rebuilds [builder] every [interval] without touching the network – used
/// for countdowns that only depend on the current time.
class _PeriodicRebuild extends StatefulWidget {
  const _PeriodicRebuild({required this.interval, required this.builder});

  final Duration interval;
  final WidgetBuilder builder;

  @override
  State<_PeriodicRebuild> createState() => _PeriodicRebuildState();
}

class _PeriodicRebuildState extends State<_PeriodicRebuild> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.interval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class _OneShotAnimationBuilder extends StatefulWidget {
  const _OneShotAnimationBuilder({
    required this.duration,
    required this.curve,
    required this.builder,
  });

  final Duration duration;
  final Curve curve;
  final Widget Function(BuildContext context, Animation<double> animation)
  builder;

  @override
  State<_OneShotAnimationBuilder> createState() =>
      _OneShotAnimationBuilderState();
}

class _OneShotAnimationBuilderState extends State<_OneShotAnimationBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _animation = CurvedAnimation(parent: _controller, curve: widget.curve);
    _controller.forward();
  }

  @override
  void dispose() {
    _animation.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) => widget.builder(context, _animation),
    );
  }
}

// Countdown-Widget für Challenge-Timer
class _ChallengeCountdown extends StatefulWidget {
  final String? expiresAt;
  final VoidCallback? onExpired;

  const _ChallengeCountdown({this.expiresAt, this.onExpired});

  @override
  State<_ChallengeCountdown> createState() => _ChallengeCountdownState();
}

class _ChallengeCountdownState extends State<_ChallengeCountdown> {
  String timeLeft = '';
  Timer? _timer;
  bool _didNotifyExpired = false;

  @override
  void initState() {
    super.initState();
    _updateTimeLeft();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        _updateTimeLeft();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ChallengeCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expiresAt != widget.expiresAt) {
      _didNotifyExpired = false;
      _updateTimeLeft();
    }
  }

  void _updateTimeLeft() {
    if (widget.expiresAt == null) {
      setState(() => timeLeft = '');
      return;
    }

    try {
      final expiresAt = DateTime.parse(widget.expiresAt!);
      final now = DateTime.now();
      final difference = expiresAt.difference(now);

      if (difference.inSeconds <= 0) {
        _timer?.cancel();
        setState(() => timeLeft = '00:00');
        if (!_didNotifyExpired) {
          _didNotifyExpired = true;
          widget.onExpired?.call();
        }
        return;
      }

      final minutes = difference.inMinutes;
      final seconds = difference.inSeconds % 60;
      setState(() {
        timeLeft =
            '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
      });
    } catch (e) {
      setState(() => timeLeft = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (timeLeft.isEmpty) return const SizedBox.shrink();

    final isUrgent = timeLeft.startsWith('0') && !timeLeft.startsWith('00:');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isUrgent ? Colors.red : Colors.white.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hourglass_empty_rounded, color: Colors.white, size: 16),
          const SizedBox(width: 4),
          Text(
            timeLeft,
            style: _inter.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChallengeWheelDialog extends StatefulWidget {
  final List<Map<String, dynamic>> challenges;

  const _ChallengeWheelDialog({required this.challenges});

  @override
  State<_ChallengeWheelDialog> createState() => _ChallengeWheelDialogState();
}

class _ChallengeWheelDialogState extends State<_ChallengeWheelDialog>
    with SingleTickerProviderStateMixin {
  static final Random _rng = Random();
  static int? _lastPickedIndex;
  late final AnimationController _controller;
  late final Animation<double> _rotation;
  AnimationStatusListener _statusListener = (_) {};
  late final int _pickedIndex;
  bool _popped = false;
  // The wheel stopped: show the task until the user starts the duel.
  bool _revealed = false;

  @override
  void initState() {
    super.initState();

    if (widget.challenges.isEmpty) {
      // Nothing to pick; close dialog safely.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _popped) return;
        _popped = true;
        Navigator.of(context).pop();
      });

      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1),
      );
      _rotation = const AlwaysStoppedAnimation<double>(0);
      _pickedIndex = 0;
      return;
    }

    final count = widget.challenges.length;
    var picked = _rng.nextInt(count);
    // Avoid landing on the same challenge repeatedly.
    if (count > 1 && _lastPickedIndex != null && picked == _lastPickedIndex) {
      picked = (picked + 1 + _rng.nextInt(count - 1)) % count;
    }
    _pickedIndex = picked;
    _lastPickedIndex = picked;

    final segment = (2 * pi) / count;
    final target = -(_pickedIndex * segment + (segment / 2));
    final total = (2 * pi * 6) + target;

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );

    _rotation = Tween<double>(
      begin: 0,
      end: total,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    _statusListener = (status) {
      if (status == AnimationStatus.completed && mounted && !_popped) {
        HapticFeedback.mediumImpact();
        setState(() => _revealed = true);
      }
    };
    _controller.addStatusListener(_statusListener);

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_statusListener);
    _controller.dispose();
    super.dispose();
  }

  static String _emojiOf(Map<String, dynamic> c) {
    return (c['emoji'] ??
            c['icon'] ??
            c['emote'] ??
            c['symbol'] ??
            c['emoji_de'] ??
            c['emoji_en'] ??
            '')
        .toString()
        .trim();
  }

  static String _taskOf(Map<String, dynamic> c) {
    return t((c['de'] ?? '').toString(), (c['en'] ?? '').toString()).trim();
  }

  void _startDuel() {
    if (_popped || widget.challenges.isEmpty) return;
    _popped = true;
    Navigator.of(context).pop(widget.challenges[_pickedIndex]);
  }

  Widget _buildPickedTask() {
    final picked = widget.challenges[_pickedIndex];
    final emoji = _emojiOf(picked);
    return Column(
      key: const ValueKey('picked'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: const Color(0xFF3A2A06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFFC14D), width: 1.2),
          ),
          child: Row(
            children: [
              if (emoji.isNotEmpty) ...[
                Text(emoji, style: const TextStyle(fontSize: 30)),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  _taskOf(picked),
                  style: _inter.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          t(
            'Ihr habt beide 30 Minuten für euer Foto. Danach stimmen alle bis zur nächsten Quest ab – mehr Likes gewinnt.',
            'You both have 30 minutes for your photo. Then everyone votes until the next quest – most likes wins.',
          ),
          textAlign: TextAlign.center,
          style: _inter.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: const Color(0xFFCFC4A8),
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _startDuel,
            icon: const Icon(Icons.flash_on_rounded, size: 20),
            label: Text(
              t("Los geht's", "Let's go"),
              style: _inter.copyWith(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFFC14D),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.challenges.map((c) {
      final emoji = _emojiOf(c);
      if (emoji.isNotEmpty) return emoji;
      return _taskOf(c);
    }).toList();

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF15221B), Color(0xFF0B0D0C)],
          ),
          border: Border.all(
            color: const Color(0xFF56F1A0).withValues(alpha: 0.45),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF57F2A2).withValues(alpha: 0.22),
              blurRadius: 26,
              spreadRadius: 2,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        // Scrolls on small phones once the task card is shown.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _revealed
                    ? t('Eure Duell-Aufgabe', 'Your duel task')
                    : t('Glücksrad dreht...', 'Spinning wheel...'),
                style: _inter.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _revealed
                    ? t('Gilt für euch beide', 'Same task for both of you')
                    : t(
                        'Deine Duell-Aufgabe wird ausgelost',
                        'Your duel task is being selected',
                      ),
                style: _inter.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 14),
              AnimatedBuilder(
                animation: _rotation,
                builder: (context, _) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 282,
                        height: 282,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF6BFFB3,
                              ).withValues(alpha: 0.2),
                              blurRadius: 34,
                              spreadRadius: 3,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        height: 260,
                        child: CustomPaint(
                          painter: _ChallengeWheelPainter(
                            labels: labels,
                            rotation: _rotation.value,
                          ),
                        ),
                      ),
                      Positioned(
                        top: 2,
                        child: CustomPaint(
                          size: const Size(24, 24),
                          painter: _WheelPointerPainter(),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: _revealed
                    ? _buildPickedTask()
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChallengeWheelPainter extends CustomPainter {
  final List<String> labels;
  final double rotation;

  _ChallengeWheelPainter({required this.labels, required this.rotation});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2;
    final count = labels.isEmpty ? 1 : labels.length;
    final sweep = (2 * pi) / count;
    final startBase = -pi / 2 + rotation;

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..color = const Color(0xFF1E2F26);
    final outerBorderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = Colors.white.withValues(alpha: 0.35);
    const palette = <Color>[
      Color(0xFF1ECF7A),
      Color(0xFF17B36B),
      Color(0xFF11D490),
      Color(0xFF0FB86B),
      Color(0xFF16C884),
      Color(0xFF1AAE62),
    ];

    for (int i = 0; i < count; i++) {
      final start = startBase + (i * sweep);
      final c = palette[i % palette.length];
      final fill = Paint()
        ..style = PaintingStyle.fill
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.withValues(alpha: 0.95), c.withValues(alpha: 0.72)],
        ).createShader(Rect.fromCircle(center: center, radius: radius));

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        true,
        fill,
      );
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep,
        true,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Colors.black.withValues(alpha: 0.2),
      );

      // Clip each label to its segment so long text can't overlap into neighbors.
      final wedge = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(
          Rect.fromCircle(center: center, radius: radius),
          start,
          sweep,
          false,
        )
        ..close();

      // Label
      final label = labels[i];
      final trimmed = label.trim();
      final isEmojiLabel =
          trimmed.isNotEmpty &&
          trimmed.runes.length <= 6 &&
          !RegExp(r'[A-Za-z0-9]').hasMatch(trimmed) &&
          !trimmed.contains(' ');

      final shortLabel = (!isEmojiLabel && label.length > 16)
          ? '${label.substring(0, 16)}...'
          : label;

      final fontSize = isEmojiLabel
          ? 30.0
          : (shortLabel.length > 14 ? 8.5 : 9.5);

      const emojiFallbackFonts = <String>[
        'Apple Color Emoji',
        'Segoe UI Emoji',
        'Noto Color Emoji',
      ];

      final textPainter = TextPainter(
        text: TextSpan(
          text: shortLabel,
          style: isEmojiLabel
              ? TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  fontFamilyFallback: emojiFallbackFonts,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 3,
                    ),
                  ],
                )
              : _inter
                    .copyWith(
                      fontSize: fontSize,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    )
                    .copyWith(fontFamilyFallback: emojiFallbackFonts),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: isEmojiLabel ? radius * 0.45 : radius * 0.62);

      final angle = start + (sweep / 2);
      final labelRadius = radius * 0.55;
      final labelPos = center + Offset(cos(angle), sin(angle)) * labelRadius;
      canvas.save();
      canvas.clipPath(wedge);
      canvas.translate(labelPos.dx, labelPos.dy);
      canvas.rotate(angle + pi / 2);
      textPainter.paint(
        canvas,
        Offset(-textPainter.width / 2, -textPainter.height / 2),
      );
      canvas.restore();
    }

    canvas.drawCircle(center, radius - 0.4, ringPaint);
    canvas.drawCircle(center, radius - 0.4, outerBorderPaint);
    canvas.drawCircle(
      center,
      radius * 0.16,
      Paint()..color = const Color(0xFF0E1612),
    );
    canvas.drawCircle(
      center,
      radius * 0.08,
      Paint()..color = const Color(0xFF86FFC3).withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(covariant _ChallengeWheelPainter oldDelegate) {
    return oldDelegate.rotation != rotation || oldDelegate.labels != labels;
  }
}

class _WheelPointerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    path.moveTo(size.width / 2, 0);
    path.lineTo(0, size.height);
    path.lineTo(size.width, size.height);
    path.close();
    canvas.drawShadow(path, Colors.black.withValues(alpha: 0.5), 4, true);
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFDF2B8), Color(0xFFD8B24E)],
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, paint);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF8D6A1A),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Instagram-style reaction chip:
/// - Press-down: scales to 0.86 with quick easeOut.
/// - Release: springs back via elasticOut → tactile, alive feel.
/// - Count change (popTick changes): spring-pop from 0.7 → 1.0 via elasticOut.
class _ReactionChip extends StatefulWidget {
  final String emoji;
  final int count;
  final bool isHeart;
  final int popTick;
  final VoidCallback onTap;

  const _ReactionChip({
    super.key,
    required this.emoji,
    required this.count,
    required this.isHeart,
    required this.popTick,
    required this.onTap,
  });

  @override
  State<_ReactionChip> createState() => _ReactionChipState();
}

class _ReactionChipState extends State<_ReactionChip>
    with TickerProviderStateMixin {
  late final AnimationController _pressCtrl;
  late final AnimationController _popCtrl;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _popCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      value: 1.0,
    );
    // No initial pop: only didUpdateWidget triggers it → no random pops
    // while scrolling, no double-animation when the parent rebuilds.
  }

  @override
  void didUpdateWidget(covariant _ReactionChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.popTick != oldWidget.popTick) {
      _popCtrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    _popCtrl.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    _pressCtrl.forward();
  }

  void _handleTapUp(TapUpDetails _) {
    _pressCtrl.reverse();
    HapticFeedback.lightImpact();
    widget.onTap();
  }

  void _handleTapCancel() {
    _pressCtrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.count > 1
        ? '${widget.emoji}${widget.count}'
        : widget.emoji;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pressCtrl, _popCtrl]),
        builder: (context, child) {
          final pressEased = Curves.easeOutCubic.transform(_pressCtrl.value);
          final pressScale = 1.0 - (0.14 * pressEased);

          // WhatsApp-style heartbeat pop: 1.0 → 1.4 → 1.0 in a smooth sine
          // arc. The chip stays at rest at 1.0 (no shrink-then-grow), pops
          // up briefly when the count changes, then settles back. Two
          // easings make the up-stroke snappier than the settle.
          double popScale;
          if (_popCtrl.value >= 1.0 && !_popCtrl.isAnimating) {
            popScale = 1.0;
          } else {
            final t = _popCtrl.value.clamp(0.0, 1.0);
            // Ease the up-phase (0 → 0.45) with easeOut for a snappy pop,
            // ease the down-phase (0.45 → 1.0) with easeInOut for a smooth
            // settle. Peak amplitude ≈ 0.42 → scale ≈ 1.42 at the apex.
            const peakAt = 0.45;
            const amp = 0.42;
            double phase;
            if (t < peakAt) {
              phase = Curves.easeOut.transform(t / peakAt);
            } else {
              phase = 1.0 -
                  Curves.easeInOut.transform((t - peakAt) / (1.0 - peakAt));
            }
            popScale = 1.0 + (amp * phase);
          }

          return Transform.scale(
            scale: pressScale * popScale,
            child: child,
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16.5,
              fontWeight: FontWeight.w600,
              color: widget.isHeart ? Colors.red : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}


/// All pending friend requests, received and sent, opened from the
/// "Friend requests" row at the top of the friends list.
class _FriendRequestsScreen extends StatefulWidget {
  const _FriendRequestsScreen({
    required this.requests,
    required this.onAccept,
    required this.onRemove,
  });

  final List<Map<String, dynamic>> requests;
  final Future<bool> Function(String friendshipId) onAccept;
  final Future<bool> Function(String friendshipId) onRemove;

  @override
  State<_FriendRequestsScreen> createState() => _FriendRequestsScreenState();
}

class _FriendRequestsScreenState extends State<_FriendRequestsScreen> {
  late final List<Map<String, dynamic>> _requests = List.of(widget.requests);
  final Set<String> _busy = <String>{};

  Future<void> _handle(
    Map<String, dynamic> request,
    Future<bool> Function(String friendshipId) action,
  ) async {
    final friendshipId = (request['friendshipId'] ?? '').toString();
    if (friendshipId.isEmpty || _busy.contains(friendshipId)) return;
    setState(() => _busy.add(friendshipId));
    final ok = await action(friendshipId);
    if (!mounted) return;
    setState(() {
      _busy.remove(friendshipId);
      if (ok) _requests.remove(request);
    });
    if (ok && _requests.isEmpty) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    const darkBg = Color(0xFF121212);
    const textSecondary = Color(0xFFAAAAAA);
    final incoming = _requests
        .where((r) => r['isRequester'] != true)
        .toList(growable: false);
    final outgoing = _requests
        .where((r) => r['isRequester'] == true)
        .toList(growable: false);

    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkBg,
        foregroundColor: Colors.white,
        title: Text(
          t('Freundschaftsanfragen', 'Friend requests'),
          style: _inter.copyWith(fontSize: 18, color: Colors.white),
        ),
      ),
      body: _requests.isEmpty
          ? Center(
              child: Text(
                t('Keine offenen Anfragen', 'No open requests'),
                style: _inter.copyWith(fontSize: 15, color: textSecondary),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
              children: [
                if (incoming.isNotEmpty) ...[
                  _sectionTitle(t('Erhalten', 'Received')),
                  for (final request in incoming)
                    _requestTile(request, incoming: true),
                ],
                if (outgoing.isNotEmpty) ...[
                  _sectionTitle(t('Gesendet', 'Sent')),
                  for (final request in outgoing)
                    _requestTile(request, incoming: false),
                ],
              ],
            ),
    );
  }

  Widget _sectionTitle(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Text(
        label.toUpperCase(),
        style: _inter.copyWith(
          fontSize: 12,
          letterSpacing: 0.6,
          color: const Color(0xFFAAAAAA),
        ),
      ),
    );
  }

  Widget _requestTile(Map<String, dynamic> request, {required bool incoming}) {
    final accentGreen = Theme.of(context).colorScheme.primary;
    final friendshipId = (request['friendshipId'] ?? '').toString();
    final busy = _busy.contains(friendshipId);
    final username = (request['username'] ?? '').toString();
    final userId = (request['id'] ?? '').toString();
    final picture = request['profile_picture'];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: userId.isEmpty
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ProfileScreen(userId: userId),
                    ),
                  ),
            child: CircleAvatar(
              radius: 22,
              backgroundColor: Colors.black,
              backgroundImage: picture != null
                  ? sideQuestCachedImageProvider(
                      picture,
                      cacheWidth: sideQuestCacheWidth(context, 44),
                      cacheHeight: sideQuestCacheWidth(context, 44),
                    )
                  : null,
              child: picture == null
                  ? Text(
                      username.isNotEmpty ? username[0].toUpperCase() : 'U',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  username,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _inter.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                Text(
                  incoming
                      ? t('Möchte dein Freund sein', 'Wants to be your friend')
                      : t('Anfrage gesendet', 'Request sent'),
                  style: _inter.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFFAAAAAA),
                  ),
                ),
              ],
            ),
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: accentGreen,
                ),
              ),
            )
          else if (incoming) ...[
            FilledButton(
              onPressed: () => _handle(request, widget.onAccept),
              style: FilledButton.styleFrom(
                backgroundColor: accentGreen,
                foregroundColor: const Color(0xFF10160F),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 36),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                t('Annehmen', 'Accept'),
                style: _inter.copyWith(fontSize: 13),
              ),
            ),
            IconButton(
              tooltip: t('Ablehnen', 'Decline'),
              onPressed: () => _handle(request, widget.onRemove),
              icon: const Icon(Icons.close, color: Colors.red, size: 22),
            ),
          ] else
            TextButton(
              onPressed: () => _handle(request, widget.onRemove),
              child: Text(
                t('Zurückziehen', 'Withdraw'),
                style: _inter.copyWith(fontSize: 13, color: Colors.red),
              ),
            ),
        ],
      ),
    );
  }
}
