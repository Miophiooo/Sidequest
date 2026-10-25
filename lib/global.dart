import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'features/daily_quest/quest_suggestion_board.dart';
import 'features/live_photo/live_photo.dart';
import 'features/media/post_media.dart';
import 'shared.dart';
import 'daily_challenges.dart';
import 'like_animation.dart';
import 'mentions.dart';
import 'profile.dart';
import 'block_service.dart';
import 'comment_filter.dart';
import 'comment_thread_service.dart';
import 'core/app_logger.dart';
import 'report_service.dart';
import 'widgets/daily_quest_mini_card.dart';
import 'widgets/likers_bottom_sheet.dart';

/// Cached Inter TextStyle – avoids repeated font-family lookups in build().
final TextStyle _inter = GoogleFonts.inter(fontWeight: FontWeight.w700);

/// Leaderboard chip thresholds. Deliberately low while the community is
/// small — revisit as daily active users grow.
const int kPopularChipLikes = 10;
const int kControversialChipLikes = 5;
const int kControversialChipDislikes = 3;
const int kControversialChipComments = 3;

class LeaderboardScreen extends StatefulWidget {
  final VoidCallback? onOpenOwnProfile;
  final VoidCallback? onOpenFriendsTab;

  const LeaderboardScreen({
    super.key,
    this.onOpenOwnProfile,
    this.onOpenFriendsTab,
  });

  @override
  State<LeaderboardScreen> createState() => LeaderboardScreenState();
}

class LeaderboardScreenState extends State<LeaderboardScreen>
    with WidgetsBindingObserver {
  static const int _initialVisibleLeaderboardItems = 10;
  static const int _leaderboardItemsPageSize = 6;
  Future<List<Map<String, dynamic>>>? _leaderboardFuture;
  List<Map<String, dynamic>> _latestLoadedLeaderboard = const [];
  Timer? _challengeBoundaryTimer;
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();
  int _visibleLeaderboardItems = _initialVisibleLeaderboardItems;
  List<String> _expandedLeaderboardPhotoIds = const [];
  // True until the user has posted for the active quest (BeReal style).
  bool _leaderboardLocked = false;
  PostFocusRequest? _pendingPostFocusRequest;
  bool _isApplyingPostFocusRequest = false;

  Future<List<Map<String, dynamic>>> _initializeLeaderboard() async {
    return _loadLeaderboard(surfaceErrors: true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _leaderboardFuture = _initializeLeaderboard();
    _scheduleAutoRefreshAtNextChallengeStart();
    postDataRefreshNotifier.addListener(_onPostDataChanged);
    postFocusRequestNotifier.addListener(_handlePostFocusRequest);
    _itemPositionsListener.itemPositions.addListener(
      _maybeLoadMoreLeaderboardItems,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handlePostFocusRequest();
    });
  }

  @override
  void dispose() {
    postDataRefreshNotifier.removeListener(_onPostDataChanged);
    postFocusRequestNotifier.removeListener(_handlePostFocusRequest);
    _challengeBoundaryTimer?.cancel();
    _itemPositionsListener.itemPositions.removeListener(
      _maybeLoadMoreLeaderboardItems,
    );
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _maybeLoadMoreLeaderboardItems() {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    final totalItems = _latestLoadedLeaderboard.length;
    if (totalItems <= _visibleLeaderboardItems) return;

    const headerSlotCount = 1;
    const topCardSlotCount = 1;
    final totalRawItems =
        headerSlotCount +
        topCardSlotCount +
        math.max(0, _visibleLeaderboardItems - 1);
    final maxVisibleIndex = positions
        .where((position) => position.itemTrailingEdge > 0)
        .map((position) => position.index)
        .fold<int>(0, math.max);
    if (maxVisibleIndex < totalRawItems - 3) return;
    if (!mounted) return;

    setState(() {
      _visibleLeaderboardItems = math.min(
        totalItems,
        _visibleLeaderboardItems + _leaderboardItemsPageSize,
      );
    });
  }

  void _onPostDataChanged() {
    if (!mounted) return;
    _refresh();
  }

  void _handlePostFocusRequest() {
    final request = postFocusRequestNotifier.value;
    if (request == null || request.tabIndex != 2) return;

    final future = _loadLeaderboard(surfaceErrors: true);
    if (!mounted) {
      _pendingPostFocusRequest = request;
      _leaderboardFuture = future;
      return;
    }

    setState(() {
      _pendingPostFocusRequest = request;
      _leaderboardFuture = future;
    });
  }

  List<String> _normalizedExpandedLeaderboardPhotoIds(
    List<Map<String, dynamic>> data, {
    List<String>? photoIds,
  }) {
    if (data.length < 2) return const [];
    final topId = (data.first['id'] ?? '').toString().trim();
    final orderByPhotoId = <String, int>{};
    for (var i = 0; i < data.length; i++) {
      final photoId = (data[i]['id'] ?? '').toString().trim();
      if (photoId.isNotEmpty) {
        orderByPhotoId[photoId] = i;
      }
    }

    final normalized =
        (photoIds ?? _expandedLeaderboardPhotoIds)
            .map((photoId) => photoId.trim())
            .where(
              (photoId) =>
                  photoId.isNotEmpty &&
                  photoId != topId &&
                  orderByPhotoId.containsKey(photoId),
            )
            .toSet()
            .toList(growable: false)
          ..sort((a, b) => orderByPhotoId[a]!.compareTo(orderByPhotoId[b]!));
    return normalized;
  }

  bool _isExpandedLeaderboardPhoto(
    String photoId,
    List<Map<String, dynamic>> data,
  ) {
    if (photoId.isEmpty) return false;
    return _normalizedExpandedLeaderboardPhotoIds(data).contains(photoId);
  }

  int _leaderboardListIndexForDataIndex(int dataIndex) {
    if (dataIndex <= 0) return 1;
    return 1 + 1 + (dataIndex - 1);
  }

  void _selectLeaderboardPost(
    Map<String, dynamic> item, {
    bool scrollToTopCard = true,
  }) {
    final photoId = (item['id'] ?? '').toString().trim();
    if (photoId.isEmpty) return;
    final topPhotoId = _latestLoadedLeaderboard.isEmpty
        ? ''
        : (_latestLoadedLeaderboard.first['id'] ?? '').toString().trim();
    if (photoId == topPhotoId) return;

    final nextExpandedIds = List<String>.from(_expandedLeaderboardPhotoIds);
    if (nextExpandedIds.contains(photoId)) {
      nextExpandedIds.remove(photoId);
    } else {
      nextExpandedIds.add(photoId);
    }
    _expandedLeaderboardPhotoIds = _normalizedExpandedLeaderboardPhotoIds(
      _latestLoadedLeaderboard,
      photoIds: nextExpandedIds,
    );

    if (mounted) {
      setState(() {});
    }
    if (scrollToTopCard && _itemScrollController.isAttached) {
      final dataIndex = _latestLoadedLeaderboard.indexWhere(
        (entry) => (entry['id'] ?? '').toString().trim() == photoId,
      );
      if (dataIndex == -1) return;
      unawaited(
        _itemScrollController.scrollTo(
          index: _leaderboardListIndexForDataIndex(dataIndex),
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: 0,
        ),
      );
    }
  }

  Future<void> _openFocusedCommentsSheet(
    String photoId, {
    String? highlightCommentId,
  }) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CommentsSheet(
        photoId: photoId,
        highlightCommentId: highlightCommentId,
      ),
    );
  }

  Future<void> scrollToTop() async {
    if (!_itemScrollController.isAttached) return;
    await _itemScrollController.scrollTo(
      index: 0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: 0,
    );
  }

  void _maybeApplyPendingPostFocusRequest(List<Map<String, dynamic>> data) {
    final request = _pendingPostFocusRequest;
    if (request == null || _isApplyingPostFocusRequest) return;

    final dataIndex = data.indexWhere(
      (item) => (item['id'] ?? '').toString() == request.photoId,
    );
    _isApplyingPostFocusRequest = true;

    if (dataIndex != -1 && _visibleLeaderboardItems < dataIndex + 1) {
      _visibleLeaderboardItems = math.min(data.length, dataIndex + 1);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;

        if (dataIndex == -1) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t(
                  'Dieser Post ist nicht im aktuellen Public Feed.',
                  'This post is not in the current public feed.',
                ),
              ),
            ),
          );
          return;
        }

        final topPhotoId = (data.first['id'] ?? '').toString().trim();
        final showingTopPost = request.photoId == topPhotoId;
        if (!showingTopPost) {
          _expandedLeaderboardPhotoIds = [
            ..._expandedLeaderboardPhotoIds,
            request.photoId,
          ];
          _expandedLeaderboardPhotoIds = _normalizedExpandedLeaderboardPhotoIds(
            data,
          );
        }
        final listIndex = _leaderboardListIndexForDataIndex(dataIndex);

        if (_itemScrollController.isAttached) {
          await _itemScrollController.scrollTo(
            index: listIndex,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOutCubic,
            alignment: 0.08,
          );
        }

        if (!mounted) return;
        if ((request.commentId ?? '').trim().isNotEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
          if (!mounted) return;
          await _openFocusedCommentsSheet(
            request.photoId,
            highlightCommentId: request.commentId,
          );
        }
      } finally {
        if (mounted) {
          setState(() => _pendingPostFocusRequest = null);
        } else {
          _pendingPostFocusRequest = null;
        }
        clearPostFocusRequest();
        _isApplyingPostFocusRequest = false;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Timers may pause while backgrounded; refresh when returning.
      _refresh();
      _scheduleAutoRefreshAtNextChallengeStart();
    }
  }

  void _scheduleAutoRefreshAtNextChallengeStart() {
    _challengeBoundaryTimer?.cancel();
    final nowLocal = DateTime.now();
    final todayStart = challengeStartLocal(nowLocal);
    final nextStart = nowLocal.isBefore(todayStart)
        ? todayStart
        : challengeStartLocal(nowLocal.add(const Duration(days: 1)));
    final delay = nextStart.difference(nowLocal) + const Duration(seconds: 1);
    if (delay.isNegative) return;
    _challengeBoundaryTimer = Timer(delay, () async {
      if (!mounted) return;
      await _refresh();
      if (mounted) {
        _scheduleAutoRefreshAtNextChallengeStart();
      }
    });
  }

  Future<List<Map<String, dynamic>>> _loadLeaderboard({
    bool surfaceErrors = false,
  }) async {
    final client = Supabase.instance.client;

    try {
      // One request: the server ranks all quest posts of the active quest
      // (blocks, counts, own likes and the Crowd Favorite included) and only
      // returns them once the user has posted.
      final result = await client.rpc(
        'leaderboard_active_quest',
        params: {'p_limit': 50},
      );
      final payload = result is Map
          ? Map<String, dynamic>.from(result)
          : const <String, dynamic>{};
      _leaderboardLocked = payload['has_posted'] != true;
      final items = [
        for (final row in (payload['items'] as List?) ?? const [])
          {
            ...Map<String, dynamic>.from(row as Map),
            'username': (row['username'] ?? 'Unknown').toString(),
          },
      ];

      _latestLoadedLeaderboard = List<Map<String, dynamic>>.from(
        items,
        growable: false,
      );
      if (items.isEmpty) {
        _expandedLeaderboardPhotoIds = const [];
      } else {
        _expandedLeaderboardPhotoIds = _normalizedExpandedLeaderboardPhotoIds(
          items,
        );
      }
      _visibleLeaderboardItems = _initialVisibleLeaderboardItems;
      return items;
    } catch (e, stackTrace) {
      AppLogger.error('Error loading leaderboard', e, stackTrace);
      _latestLoadedLeaderboard = const [];
      _visibleLeaderboardItems = _initialVisibleLeaderboardItems;
      if (surfaceErrors) {
        rethrow;
      }
      return [];
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _leaderboardFuture = _loadLeaderboard(surfaceErrors: true);
    });
    try {
      await _leaderboardFuture;
    } catch (_) {
      // The FutureBuilder renders the actual error state.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Instagram-style dark colors
    const darkBg = Color(0xFF121212);
    const textPrimary = Colors.white;
    final accentGreen = Theme.of(context).colorScheme.primary;
    final adaptive = sideQuestAdaptiveLayoutOf(context);
    final scale = adaptive.scale(minScale: 0.82, maxScale: 1.0);
    final pageHorizontalPadding = adaptive.isUltraNarrowWidth ? 12.0 : 16.0;
    final bottomContentPadding =
        adaptive.bottomNavHeight +
        adaptive.bottomNavBottomOffset(isKeyboardOpen: false) +
        MediaQuery.paddingOf(context).bottom +
        (24 * scale);

    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkBg,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 20,
        title: Row(
          children: [
            Icon(Icons.public, color: accentGreen, size: 24 * scale),
            SizedBox(width: 8 * scale),
            Text(
              t('Leaderboard', 'Leaderboard'),
              style: _inter.copyWith(
                fontSize: 24 * scale,
                fontWeight: FontWeight.w700,
                color: textPrimary,
              ),
            ),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _leaderboardFuture,
          builder: (context, snapshot) {
            Widget child;

            if (snapshot.connectionState == ConnectionState.waiting) {
              child = ListView(
                key: const ValueKey('leaderboard_loading'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  pageHorizontalPadding,
                  14 * scale,
                  pageHorizontalPadding,
                  bottomContentPadding,
                ),
                children: [
                  const RepaintBoundary(child: DailyQuestMiniCard()),
                  SizedBox(height: 60 * scale),
                  const Center(child: CircularProgressIndicator()),
                ],
              );
            } else if (snapshot.hasError) {
              child = ListView(
                key: const ValueKey('leaderboard_error'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  pageHorizontalPadding,
                  14 * scale,
                  pageHorizontalPadding,
                  bottomContentPadding,
                ),
                children: [
                  const RepaintBoundary(child: DailyQuestMiniCard()),
                  SizedBox(height: 60 * scale),
                  Center(
                    child: Text(
                      t(
                        'Konnte nicht geladen werden – zum Aktualisieren nach unten ziehen.',
                        "Couldn't load – pull down to refresh.",
                      ),
                      textAlign: TextAlign.center,
                      style: _inter.copyWith(color: Colors.white70),
                    ),
                  ),
                ],
              );
            } else {
              final data = snapshot.data ?? _latestLoadedLeaderboard;
              _maybeApplyPendingPostFocusRequest(data);
              if (data.isEmpty) {
                child = ListView(
                  key: const ValueKey('leaderboard_empty'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    pageHorizontalPadding,
                    14 * scale,
                    pageHorizontalPadding,
                    bottomContentPadding,
                  ),
                  children: [
                    const RepaintBoundary(child: DailyQuestMiniCard()),
                    const RepaintBoundary(child: QuestSuggestionBoard()),
                    SizedBox(height: 40 * scale),
                    if (_leaderboardLocked)
                      _LockedLeaderboardHint(scale: scale)
                    else
                      Center(
                        child: Text(
                          t(
                            'Noch keine öffentlichen Posts heute',
                            'No public posts today yet',
                          ),
                          style: _inter.copyWith(
                            fontSize: 16 * scale,
                            color: Colors.white70,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                );
              } else {
                const headerSlotCount = 1;
                const topCardSlotCount = 1;
                final visibleData = data
                    .take(_visibleLeaderboardItems)
                    .toList(growable: false);
                final topItem = data.first;
                final rankedEntries = visibleData
                    .skip(1)
                    .toList(growable: false);
                child = ScrollablePositionedList.builder(
                  key: const ValueKey('leaderboard_list'),
                  itemScrollController: _itemScrollController,
                  itemPositionsListener: _itemPositionsListener,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    pageHorizontalPadding,
                    14 * scale,
                    pageHorizontalPadding,
                    bottomContentPadding,
                  ),
                  itemCount:
                      headerSlotCount +
                      topCardSlotCount +
                      rankedEntries.length,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      // Daily-quest mini-card replaces the old spacer in the
                      // header slot so the prompt is visible at the top of
                      // the leaderboard (scrolls along with the list). The
                      // community quest board rides directly below it.
                      return const RepaintBoundary(
                        child: Column(
                          children: [
                            DailyQuestMiniCard(),
                            QuestSuggestionBoard(),
                          ],
                        ),
                      );
                    }

                    if (i == 1) {
                      return RepaintBoundary(
                        child: _TopPostCard(
                          key: ValueKey(
                            'leaderboard_top_${(topItem['id'] ?? '').toString()}',
                          ),
                          item: topItem,
                          onOpenOwnProfile: widget.onOpenOwnProfile,
                        ),
                      );
                    }

                    final tileIndex = i - headerSlotCount - topCardSlotCount;
                    final item = rankedEntries[tileIndex];
                    final photoId = (item['id'] ?? '').toString().trim();
                    final rank = tileIndex + 2;
                    final isExpanded = _isExpandedLeaderboardPhoto(
                      photoId,
                      data,
                    );
                    if (isExpanded) {
                      return _AnimatedExpandedLeaderboardCard(
                        key: ValueKey('leaderboard_expanded_$photoId'),
                        child: RepaintBoundary(
                          child: _TopPostCard(
                            key: ValueKey('leaderboard_expanded_card_$photoId'),
                            item: item,
                            onOpenOwnProfile: widget.onOpenOwnProfile,
                            onCollapse: () => _selectLeaderboardPost(
                              item,
                              scrollToTopCard: false,
                            ),
                          ),
                        ),
                      );
                    }

                    return RepaintBoundary(
                      child: _RankedPostTile(
                        rank: rank,
                        item: item,
                        isSelected: false,
                        onSelect: () => _selectLeaderboardPost(item),
                        onOpenOwnProfile: widget.onOpenOwnProfile,
                      ),
                    );
                  },
                );
              }
            }

            final isLeaderboardList =
                child.key == const ValueKey('leaderboard_list');
            if (isLeaderboardList) return child;

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
              child: child,
            );
          },
        ),
      ),
    );
  }
}


/// Shown instead of the ranking until the user has posted for the quest.
class _LockedLeaderboardHint extends StatelessWidget {
  const _LockedLeaderboardHint({required this.scale});

  final double scale;

  @override
  Widget build(BuildContext context) {
    final accentGreen = Theme.of(context).colorScheme.primary;
    return Container(
      padding: EdgeInsets.fromLTRB(
        20 * scale,
        22 * scale,
        20 * scale,
        18 * scale,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accentGreen.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Icon(Icons.lock_rounded, color: accentGreen, size: 34 * scale),
          SizedBox(height: 10 * scale),
          Text(
            t('Erst posten, dann schauen', 'Post first, then look'),
            textAlign: TextAlign.center,
            style: _inter.copyWith(
              fontSize: 18 * scale,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          SizedBox(height: 6 * scale),
          Text(
            t(
              'Poste dein Foto zur heutigen Quest, dann siehst du die Rangliste.',
              "Post your photo for today's quest to see the leaderboard.",
            ),
            textAlign: TextAlign.center,
            style: _inter.copyWith(
              fontSize: 14 * scale,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
              height: 1.35,
            ),
          ),
          SizedBox(height: 16 * scale),
          SizedBox(
            width: double.infinity,
            height: 46 * scale,
            child: ElevatedButton.icon(
              onPressed: () => requestMainTabNavigation(0),
              icon: const Icon(Icons.photo_camera_rounded, size: 20),
              label: Text(
                t('Zur Quest', 'Go to the quest'),
                style: _inter.copyWith(
                  fontSize: 15 * scale,
                  fontWeight: FontWeight.w800,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: accentGreen,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedExpandedLeaderboardCard extends StatefulWidget {
  final Widget child;

  const _AnimatedExpandedLeaderboardCard({super.key, required this.child});

  @override
  State<_AnimatedExpandedLeaderboardCard> createState() =>
      _AnimatedExpandedLeaderboardCardState();
}

class _AnimatedExpandedLeaderboardCardState
    extends State<_AnimatedExpandedLeaderboardCard>
    with SingleTickerProviderStateMixin {
  // Plays once on first build (like the former TweenAnimationBuilder 0 -> 1).
  // The fade runs on the compositing layer (FadeTransition) instead of an
  // Opacity that repaints the card every frame.
  late final AnimationController _controller;
  late final CurvedAnimation _progress;
  late final CurvedAnimation _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: kDurationFast);
    _progress = CurvedAnimation(parent: _controller, curve: kCurveStandard);
    _opacity = CurvedAnimation(parent: _progress, curve: Curves.easeOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _opacity.dispose();
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: AnimatedBuilder(
        animation: _progress,
        child: widget.child,
        builder: (context, animatedChild) {
          final value = _progress.value;
          return Transform.translate(
            offset: Offset(0, (1 - value) * 10),
            child: ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: math.max(value, 0.001),
                child: animatedChild,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TopPostCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final VoidCallback? onOpenOwnProfile;
  final VoidCallback? onCollapse;

  const _TopPostCard({
    super.key,
    required this.item,
    this.onOpenOwnProfile,
    this.onCollapse,
  });

  @override
  State<_TopPostCard> createState() => _TopPostCardState();
}

class _TopPostCardState extends State<_TopPostCard>
    with SingleTickerProviderStateMixin {
  late bool _isLiked;
  late bool _isDisliked;
  late int _likeCount;
  late int _dislikeCount;
  bool _isAnimatingLike = false;
  bool _isAnimatingDislike = false;
  bool _isCollapsing = false;
  // Collapse animation (formerly a TweenAnimationBuilder 1 -> 0): the fade
  // runs on the compositing layer (FadeTransition) instead of an Opacity that
  // repaints the card every frame.
  late final AnimationController _collapseController;
  late final CurvedAnimation _collapseCurve;
  late final Animation<double> _collapseValue;
  late final CurvedAnimation _collapseOpacity;

  void _syncFromItem() {
    _isLiked = widget.item['is_liked'] == true;
    _isDisliked = widget.item['is_disliked'] == true;
    _likeCount = widget.item['likes_count'] ?? 0;
    _dislikeCount = widget.item['dislikes_count'] ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _syncFromItem();
    _collapseController = AnimationController(
      vsync: this,
      duration: kDurationFast,
    );
    _collapseController.addStatusListener((status) {
      if (status.isCompleted && _isCollapsing) {
        widget.onCollapse?.call();
      }
    });
    _collapseCurve = CurvedAnimation(
      parent: _collapseController,
      curve: kCurveStandard,
    );
    _collapseValue = Tween<double>(begin: 1, end: 0).animate(_collapseCurve);
    _collapseOpacity = CurvedAnimation(
      parent: _collapseValue,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _collapseOpacity.dispose();
    _collapseCurve.dispose();
    _collapseController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _TopPostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item['id'] != widget.item['id'] ||
        oldWidget.item['likes_count'] != widget.item['likes_count'] ||
        oldWidget.item['dislikes_count'] != widget.item['dislikes_count'] ||
        oldWidget.item['is_liked'] != widget.item['is_liked'] ||
        oldWidget.item['is_disliked'] != widget.item['is_disliked']) {
      _syncFromItem();
    }
  }

  Future<void> _toggleLike() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;

      if (_isLiked) {
        // Optimistic unlike: update UI immediately, revert on failure
        final previousCount = _likeCount;
        setState(() {
          _isLiked = false;
          _likeCount = _likeCount > 0 ? _likeCount - 1 : 0;
        });
        try {
          await client
              .from('likes')
              .delete()
              .eq('photo_id', widget.item['id'])
              .eq('user_id', userId);
        } catch (_) {
          if (mounted) {
            setState(() {
              _isLiked = true;
              _likeCount = previousCount;
            });
          }
          rethrow;
        }
      } else {
        // Optimistic like: update UI immediately
        setState(() {
          _isAnimatingLike = true;
          _isLiked = true;
          _likeCount++;
        });
        try {
          await client.from('likes').insert({
            'photo_id': widget.item['id'],
            'user_id': userId,
            'created_at': DateTime.now().toIso8601String(),
          });
        } catch (likeError) {
          AppLogger.debug('Like error (likely duplicate): $likeError');
        } finally {
          await Future.delayed(const Duration(milliseconds: 300));
          if (mounted) {
            setState(() {
              _isAnimatingLike = false;
            });
          }
        }
      }
    } catch (e) {
      AppLogger.debug('Error toggling like: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Fehler beim Like', 'Error liking'))),
        );
      }
    }
  }

  Future<void> _toggleDislike() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;

      if (_isDisliked) {
        // Optimistic un-dislike: update UI immediately, revert on failure
        final previousCount = _dislikeCount;
        setState(() {
          _isDisliked = false;
          _dislikeCount = _dislikeCount > 0 ? _dislikeCount - 1 : 0;
        });
        try {
          await client
              .from('dislikes')
              .delete()
              .eq('photo_id', widget.item['id'])
              .eq('user_id', userId);
        } catch (_) {
          if (mounted) {
            setState(() {
              _isDisliked = true;
              _dislikeCount = previousCount;
            });
          }
          rethrow;
        }
      } else {
        // Optimistic dislike: update UI immediately
        setState(() {
          _isAnimatingDislike = true;
          _isDisliked = true;
          _dislikeCount++;
        });
        try {
          await client.from('dislikes').insert({
            'photo_id': widget.item['id'],
            'user_id': userId,
            'created_at': DateTime.now().toIso8601String(),
          });
        } catch (dislikeError) {
          AppLogger.debug('Dislike error (likely duplicate): $dislikeError');
        } finally {
          await Future.delayed(const Duration(milliseconds: 300));
          if (mounted) {
            setState(() {
              _isAnimatingDislike = false;
            });
          }
        }
      }
    } catch (e) {
      AppLogger.debug('Error toggling dislike: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Fehler beim Dislike', 'Error disliking'))),
        );
      }
    }
  }

  String _displayUsername() {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final username = (widget.item['username'] ?? 'Unknown').toString();
    final postUserId = widget.item['user_id']?.toString();
    final crown = widget.item['is_crowd_favorite'] == true ? ' 👑' : '';
    if (postUserId != null && postUserId == currentUserId) {
      return '$username (${t('Du', 'You')})$crown';
    }
    return '$username$crown';
  }

  void _triggerCollapse() {
    if (_isCollapsing || widget.onCollapse == null) return;
    setState(() => _isCollapsing = true);
    _collapseController.forward();
  }

  @override
  Widget build(BuildContext context) {
    // Instagram-style dark colors
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final previewWidth = math.min(
      MediaQuery.of(context).size.width - 32,
      420.0,
    );
    final previewHeight = math.min(previewWidth * 0.82, 320.0);
    final cardContent = Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: cardDark,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A2A2A), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: SizedBox(
              width: double.infinity,
              height: previewHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LivePhotoFeedMedia(
                    stillUrl: widget.item['url']?.toString() ?? '',
                    attachment: LivePhotoPostAttachment.fromPostMap(
                      widget.item,
                    ),
                    preloadVideo: false,
                    // Tap-to-open-fullscreen removed in the leaderboard:
                    // the expanded top-post card is already large, so opening
                    // a second blown-up dialog on tap was redundant. Long-press
                    // for live-photo playback still works because that's a
                    // separate gesture inside LivePhotoFeedMedia.
                    width: previewWidth,
                    height: previewHeight,
                    fit: BoxFit.cover,
                    alignment: const Alignment(0, 0),
                    cacheWidth: sideQuestCacheWidth(context, previewWidth),
                    cacheHeight: sideQuestCacheWidth(context, previewHeight),
                    filterQuality: FilterQuality.low,
                  ),
                  Positioned(
                    top: 12,
                    right: widget.onCollapse != null ? 54 : 12,
                    child: _LeaderboardPostMenuButton(
                      item: widget.item,
                      size: 22,
                      overlay: true,
                    ),
                  ),
                  if (widget.onCollapse != null)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _triggerCollapse,
                          borderRadius: BorderRadius.circular(999),
                          child: Ink(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.34),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                            ),
                            child: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 22,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        final targetUserId = widget.item['user_id']?.toString();
                        if (targetUserId != null && targetUserId.isNotEmpty) {
                          final currentUserId =
                              Supabase.instance.client.auth.currentUser?.id;
                          if (targetUserId == currentUserId) {
                            widget.onOpenOwnProfile?.call();
                            return;
                          }
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  ProfileScreen(userId: targetUserId),
                            ),
                          );
                          return;
                        }
                        showProfilePictureDialog(
                          context,
                          widget.item['avatar'] as String?,
                          (widget.item['username'] as String?) ?? 'Unknown',
                        );
                      },
                      child: CircleAvatar(
                        radius: 22,
                        backgroundImage: widget.item['avatar'] != null
                            ? sideQuestCachedImageProvider(
                                widget.item['avatar'],
                                cacheWidth: sideQuestCacheWidth(context, 44),
                                cacheHeight: sideQuestCacheWidth(context, 44),
                              )
                            : null,
                        backgroundColor: appGreen,
                        child: widget.item['avatar'] == null
                            ? Text(
                                (widget.item['username'] ?? 'U')[0]
                                    .toUpperCase(),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color.fromARGB(255, 255, 255, 255),
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
                            _displayUsername(),
                            style: _inter.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: textPrimary,
                            ),
                          ),
                          Text(
                            widget.item['is_crowd_favorite'] == true
                                ? t(
                                    'Crowd Favorite · +3 Joker',
                                    'Crowd Favorite · +3 jokers',
                                  )
                                : t('Post des Tages', 'Post of the day'),
                            style: _inter.copyWith(
                              color: widget.item['is_crowd_favorite'] == true
                                  ? const Color(0xFFFFC14D)
                                  : appGreen,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Builder(
                            builder: (context) {
                              final likeCount = _likeCount;
                              final dislikeCount = _dislikeCount;
                              final commentsCount =
                                  (widget.item['comments_count'] ?? 0) as int;

                              // Thresholds sized for the current community —
                              // at 50 likes the chip was unreachable and the
                              // label never appeared for anyone.
                              final isPopular = likeCount >= kPopularChipLikes;
                              final isControversial =
                                  likeCount >= kControversialChipLikes &&
                                  dislikeCount >= kControversialChipDislikes &&
                                  commentsCount >= kControversialChipComments;

                              if (!isPopular && !isControversial) {
                                return const SizedBox.shrink();
                              }

                              final labels = <String>[];
                              // Not "Crowd Favorite": that is the daily title.
                              if (isPopular) {
                                labels.add(t('Beliebt', 'Popular'));
                              }
                              if (isControversial) {
                                labels.add(t('Kontrovers', 'Controversial'));
                              }

                              return Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  labels.join(' · '),
                                  style: _inter.copyWith(
                                    color: textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              );
                            },
                          ),
                          if (((widget.item['post_description'] ?? '')
                              .toString()
                              .trim()
                              .isNotEmpty))
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: MentionText(
                                text: (widget.item['post_description'] ?? '')
                                    .toString(),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: _inter.copyWith(
                                  color: textSecondary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                                mentionStyle: _inter.copyWith(
                                  color: appGreen,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                                enableProfileNavigation: true,
                              ),
                            ),
                          if ((widget.item['challenge_description'] ?? '')
                                  is String &&
                              (widget.item['challenge_description'] ?? '')
                                  .toString()
                                  .isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: MentionText(
                                text:
                                    '${t('Duell-Aufgabe', 'Duel task')}: ${(widget.item['challenge_description'] ?? '').toString()}',
                                style: _inter.copyWith(
                                  color: Colors.deepPurple,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                                mentionStyle: _inter.copyWith(
                                  color: appGreen,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                                enableProfileNavigation: true,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    // Heart toggles, count opens the likers sheet — split so
                    // each gesture has its own tap target.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: _toggleLike,
                          child: LikeAnimation(
                            isAnimating: _isAnimatingLike,
                            child: Icon(
                              _isLiked
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: _isLiked ? Colors.red : textSecondary,
                              size: 24,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _likeCount > 0
                              ? () => showLikersBottomSheet(
                                  context,
                                  (widget.item['id'] ?? '').toString(),
                                  onOpenOwnProfile: widget.onOpenOwnProfile,
                                )
                              : null,
                          child: Text(
                            _likeCount.toString(),
                            style: _inter.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: _toggleDislike,
                      child: LikeAnimation(
                        isAnimating: _isAnimatingDislike,
                        showParticles: true,
                        isDislike: true,
                        child: Row(
                          children: [
                            Image.asset(
                              _isDisliked
                                  ? 'assets/poop_filled.png'
                                  : 'assets/poop_outline.png',
                              width: 28,
                              height: 28,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _dislikeCount.toString(),
                              style: _inter.copyWith(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                                color: textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: () => _showCommentsSheet(),
                      child: Row(
                        children: [
                          ThoughtBubbleIcon(color: const Color(0xFFB39DFF), size: 23),
                          const SizedBox(width: 6),
                          Text(
                            (widget.item['comments_count'] ?? 0).toString(),
                            style: _inter.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              color: textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return FadeTransition(
      opacity: _collapseOpacity,
      child: AnimatedBuilder(
        animation: _collapseValue,
        child: cardContent,
        builder: (context, animatedChild) {
          final value = _collapseValue.value;
          return Transform.translate(
            offset: Offset(0, (1 - value) * 10),
            child: ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: math.max(value, 0.001),
                child: animatedChild,
              ),
            ),
          );
        },
      ),
    );
  }

  void _showCommentsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CommentsSheet(photoId: widget.item['id']),
    );
  }
}

class _RankedPostTile extends StatefulWidget {
  final int rank;
  final Map<String, dynamic> item;
  final bool isSelected;
  final VoidCallback? onSelect;
  final VoidCallback? onOpenOwnProfile;

  const _RankedPostTile({
    required this.rank,
    required this.item,
    this.isSelected = false,
    this.onSelect,
    this.onOpenOwnProfile,
  });

  @override
  State<_RankedPostTile> createState() => _RankedPostTileState();
}

class _RankedPostTileState extends State<_RankedPostTile> {
  late bool _isLiked;
  late bool _isDisliked;
  late int _likeCount;
  late int _dislikeCount;
  bool _isAnimatingLike = false;
  bool _isAnimatingDislike = false;

  void _syncFromItem() {
    _isLiked = widget.item['is_liked'] == true;
    _isDisliked = widget.item['is_disliked'] == true;
    _likeCount = widget.item['likes_count'] ?? 0;
    _dislikeCount = widget.item['dislikes_count'] ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _syncFromItem();
  }

  @override
  void didUpdateWidget(covariant _RankedPostTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item['id'] != widget.item['id'] ||
        oldWidget.item['likes_count'] != widget.item['likes_count'] ||
        oldWidget.item['dislikes_count'] != widget.item['dislikes_count'] ||
        oldWidget.item['is_liked'] != widget.item['is_liked'] ||
        oldWidget.item['is_disliked'] != widget.item['is_disliked']) {
      _syncFromItem();
    }
  }

  Future<void> _toggleLike() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;

      if (_isLiked) {
        // Optimistic unlike: update UI immediately, revert on failure
        final previousCount = _likeCount;
        setState(() {
          _isLiked = false;
          _likeCount = _likeCount > 0 ? _likeCount - 1 : 0;
        });
        try {
          await client
              .from('likes')
              .delete()
              .eq('photo_id', widget.item['id'])
              .eq('user_id', userId);
        } catch (_) {
          if (mounted) {
            setState(() {
              _isLiked = true;
              _likeCount = previousCount;
            });
          }
          rethrow;
        }
      } else {
        // Optimistic like: update UI immediately
        setState(() {
          _isAnimatingLike = true;
          _isLiked = true;
          _likeCount++;
        });
        try {
          await client.from('likes').insert({
            'photo_id': widget.item['id'],
            'user_id': userId,
            'created_at': DateTime.now().toIso8601String(),
          });
        } catch (likeError) {
          AppLogger.debug('Like error (likely duplicate): $likeError');
        } finally {
          await Future.delayed(const Duration(milliseconds: 300));
          if (mounted) {
            setState(() {
              _isAnimatingLike = false;
            });
          }
        }
      }
    } catch (e) {
      AppLogger.debug('Error toggling like: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Fehler beim Like', 'Error liking'))),
        );
      }
    }
  }

  Future<void> _toggleDislike() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;

      if (_isDisliked) {
        // Optimistic un-dislike: update UI immediately, revert on failure
        final previousCount = _dislikeCount;
        setState(() {
          _isDisliked = false;
          _dislikeCount = _dislikeCount > 0 ? _dislikeCount - 1 : 0;
        });
        try {
          await client
              .from('dislikes')
              .delete()
              .eq('photo_id', widget.item['id'])
              .eq('user_id', userId);
        } catch (_) {
          if (mounted) {
            setState(() {
              _isDisliked = true;
              _dislikeCount = previousCount;
            });
          }
          rethrow;
        }
      } else {
        // Optimistic dislike: update UI immediately
        setState(() {
          _isAnimatingDislike = true;
          _isDisliked = true;
          _dislikeCount++;
        });
        try {
          await client.from('dislikes').insert({
            'photo_id': widget.item['id'],
            'user_id': userId,
            'created_at': DateTime.now().toIso8601String(),
          });
        } catch (dislikeError) {
          AppLogger.debug('Dislike error (likely duplicate): $dislikeError');
        } finally {
          await Future.delayed(const Duration(milliseconds: 300));
          if (mounted) {
            setState(() {
              _isAnimatingDislike = false;
            });
          }
        }
      }
    } catch (e) {
      AppLogger.debug('Error toggling dislike: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Fehler beim Dislike', 'Error disliking'))),
        );
      }
    }
  }

  String _displayUsername() {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final username = (widget.item['username'] ?? 'Unknown').toString();
    final postUserId = widget.item['user_id']?.toString();
    final crown = widget.item['is_crowd_favorite'] == true ? ' 👑' : '';
    if (postUserId != null && postUserId == currentUserId) {
      return '$username (${t('Du', 'You')})$crown';
    }
    return '$username$crown';
  }

  @override
  Widget build(BuildContext context) {
    // Instagram-style dark colors
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final rankBadgeColor = switch (widget.rank) {
      1 => Colors.amber,
      2 => const Color(0xFFD7DCE2),
      3 => const Color(0xFFCD8A5C),
      _ => const Color(0xFF2A2A2A),
    };
    final rankTextColor = widget.rank <= 3
        ? const Color(0xFF151515)
        : textPrimary;
    final tileBorderColor = widget.isSelected
        ? appGreen.withValues(alpha: 0.9)
        : const Color(0xFF2A2A2A);
    final tileBackgroundColor = widget.isSelected
        ? const Color(0xFF232820)
        : cardDark;

    return GestureDetector(
      onTap: widget.onSelect,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tileBackgroundColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tileBorderColor, width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: rankBadgeColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${widget.rank}',
                    style: _inter.copyWith(
                      fontWeight: FontWeight.w800,
                      color: rankTextColor,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 60,
                    height: 60,
                    child: LivePhotoFeedMedia(
                      // 60 px tile: the small list version is enough.
                      stillUrl: listImageUrl(widget.item),
                      attachment: LivePhotoPostAttachment.fromPostMap(
                        widget.item,
                      ),
                      preloadVideo: false,
                      onTap: widget.onSelect,
                      borderRadius: BorderRadius.circular(10),
                      fit: BoxFit.cover,
                      cacheWidth: sideQuestCacheWidth(context, 60),
                      cacheHeight: sideQuestCacheWidth(context, 60),
                      filterQuality: FilterQuality.low,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayUsername(),
                        style: _inter.copyWith(
                          fontWeight: FontWeight.w700,
                          color: textPrimary,
                        ),
                      ),
                      if (((widget.item['post_description'] ?? '')
                          .toString()
                          .trim()
                          .isNotEmpty))
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: MentionText(
                            text: (widget.item['post_description'] ?? '')
                                .toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _inter.copyWith(
                              fontWeight: FontWeight.w500,
                              fontSize: 11,
                              color: textSecondary,
                            ),
                            mentionStyle: _inter.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                              color: appGreen,
                            ),
                            enableProfileNavigation: true,
                          ),
                        ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GestureDetector(
                                onTap: _toggleLike,
                                child: LikeAnimation(
                                  isAnimating: _isAnimatingLike,
                                  child: Icon(
                                    _isLiked
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: _isLiked
                                        ? Colors.red
                                        : textSecondary,
                                    size: 16,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: _likeCount > 0
                                    ? () => showLikersBottomSheet(
                                        context,
                                        (widget.item['id'] ?? '').toString(),
                                      )
                                    : null,
                                child: Text(
                                  _likeCount.toString(),
                                  style: _inter.copyWith(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                    color: textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 16),
                          GestureDetector(
                            onTap: _toggleDislike,
                            child: LikeAnimation(
                              isAnimating: _isAnimatingDislike,
                              showParticles: true,
                              isDislike: true,
                              child: Row(
                                children: [
                                  Image.asset(
                                    _isDisliked
                                        ? 'assets/poop_filled.png'
                                        : 'assets/poop_outline.png',
                                    width: 20,
                                    height: 20,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _dislikeCount.toString(),
                                    style: _inter.copyWith(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                      color: textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          GestureDetector(
                            onTap: () => _showCommentsSheet(),
                            child: Row(
                              children: [
                                ThoughtBubbleIcon(color: const Color(0xFFB39DFF), size: 16),
                                const SizedBox(width: 4),
                                Text(
                                  (widget.item['comments_count'] ?? 0)
                                      .toString(),
                                  style: _inter.copyWith(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                    color: textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Align(
                  alignment: Alignment.topRight,
                  child: _LeaderboardPostMenuButton(item: widget.item, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showCommentsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CommentsSheet(photoId: widget.item['id']),
    );
  }
}

class _CommentsSheet extends StatefulWidget {
  final String photoId;
  final String? highlightCommentId;

  const _CommentsSheet({required this.photoId, this.highlightCommentId});

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  List<Map<String, dynamic>> _comments = [];
  bool _isLoading = true;
  bool _isSending = false;
  final _commentController = TextEditingController();
  final Map<String, GlobalKey> _commentKeys = {};
  final Set<String> _commentLikeInFlightIds = <String>{};

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  GlobalKey _commentKeyFor(String commentId) {
    return _commentKeys.putIfAbsent(commentId, () => GlobalKey());
  }

  void _scrollToHighlightedComment() {
    final highlightedCommentId = (widget.highlightCommentId ?? '').trim();
    if (highlightedCommentId.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _commentKeys[highlightedCommentId]?.currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.12,
      );
    });
  }

  String _commentModerationMessage(CommentModerationIssue? issue) {
    switch (issue) {
      case CommentModerationIssue.empty:
        return t('Bitte gib einen Kommentar ein', 'Please enter a comment');
      case CommentModerationIssue.tooLong:
        return t(
          'Kommentar ist zu lang (max. 280 Zeichen)',
          'Comment is too long (max 280 chars)',
        );
      case CommentModerationIssue.abusiveLanguage:
        return t(
          'Bitte keine beleidigende Sprache in Kommentaren',
          'Please avoid abusive language in comments',
        );
      case null:
        return t('Kommentar ist nicht erlaubt', 'Comment is not allowed');
    }
  }

  Future<void> _loadComments() async {
    try {
      final loadedComments = await CommentThreadService.loadComments(
        client: Supabase.instance.client,
        photoIds: [widget.photoId],
      );

      if (mounted) {
        setState(() {
          _comments = loadedComments;
          _isLoading = false;
        });
        _scrollToHighlightedComment();
      }
    } catch (e) {
      AppLogger.debug('Error loading comments: $e');
      if (mounted) {
        setState(() {
          _comments = [];
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _addComment() async {
    final moderation = CommentFilter.validate(_commentController.text);
    if (!moderation.isAllowed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_commentModerationMessage(moderation.issue))),
        );
      }
      return;
    }

    setState(() => _isSending = true);

    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;

      final insertedComment = await client
          .from('comments')
          .insert({
            'photo_id': widget.photoId,
            'user_id': userId,
            'message': moderation.sanitized,
            'created_at': DateTime.now().toIso8601String(),
          })
          .select('id')
          .single();
      final insertedCommentId = (insertedComment['id'] ?? '').toString();

      await MentionService.createMentionNotifications(
        text: moderation.sanitized,
        entityKind: MentionEntityKind.comment,
        photoId: widget.photoId,
        commentId: insertedCommentId,
      );

      _commentController.clear();
      await _loadComments();
    } catch (e) {
      AppLogger.debug('Error adding comment: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('Fehler beim Kommentar', 'Error posting comment')),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  Future<void> _deleteComment(String commentId) async {
    // Optimistisches Update
    setState(() {
      _comments.removeWhere((c) => c['id'] == commentId);
    });

    try {
      final client = Supabase.instance.client;
      await client.from('comments').delete().eq('id', commentId);
    } catch (e) {
      AppLogger.debug('Error deleting comment: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('Fehler beim Löschen', 'Error deleting comment')),
          ),
        );
        _loadComments(); // Bei Fehler neu laden
      }
    }
  }

  Future<void> _toggleCommentLike(String commentId, bool isLiked) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id ?? '';
    if (commentId.isEmpty ||
        userId.isEmpty ||
        !_commentLikeInFlightIds.add(commentId)) {
      return;
    }

    // Optimistisches Update
    setState(() {
      final index = _comments.indexWhere((c) => c['id'] == commentId);
      if (index != -1) {
        _comments[index]['is_liked'] = !isLiked;
        _comments[index]['likes_count'] =
            (_comments[index]['likes_count'] ?? 0) + (isLiked ? -1 : 1);
      }
    });

    try {
      await sideQuestPersistCommentLike(
        client: client,
        commentId: commentId,
        userId: userId,
        shouldLike: !isLiked,
      );
    } catch (e) {
      AppLogger.debug('Error toggling comment like: $e');
      // Bei Fehler zurücksetzen
      if (mounted) {
        _loadComments();
      }
    } finally {
      _commentLikeInFlightIds.remove(commentId);
    }
  }

  void _showCommentsSnackBar(String de, String en) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t(de, en))));
  }

  Future<bool> _confirmReportDialog({
    required String titleDe,
    required String titleEn,
    required String messageDe,
    required String messageEn,
  }) async {
    if (!mounted) return false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          t(titleDe, titleEn),
          style: _inter.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          t(messageDe, messageEn),
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

  Future<void> _reportComment(Map<String, dynamic> comment) async {
    final commentId = (comment['id'] ?? '').toString();
    if (commentId.isEmpty) return;
    final confirmed = await _confirmReportDialog(
      titleDe: 'Kommentar melden?',
      titleEn: 'Report comment?',
      messageDe: 'Bist du sicher, dass du diesen Kommentar melden möchtest?',
      messageEn: 'Are you sure that you want to report this comment?',
    );
    if (!confirmed) return;

    try {
      final result = await ReportService.submit(
        client: Supabase.instance.client,
        targetType: ReportTargetType.comment,
        photoId: widget.photoId,
        commentId: commentId,
        reportedUserId: (comment['user_id'] ?? '').toString(),
      );
      if (result == ReportSubmissionResult.alreadyReported) {
        _showCommentsSnackBar(
          'Du hast diesen Kommentar bereits gemeldet',
          'You already reported this comment',
        );
      } else {
        _showCommentsSnackBar('Kommentar gemeldet', 'Comment reported');
      }
    } catch (e) {
      AppLogger.debug('Error reporting comment in leaderboard sheet: $e');
      _showCommentsSnackBar(
        'Melden des Kommentars fehlgeschlagen',
        'Reporting the comment failed',
      );
    }
  }

  Future<void> _showCommentActions(Map<String, dynamic> comment) async {
    final isOwn = comment['is_own'] == true;
    final action = await showModalBottomSheet<String>(
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
                  t('Kommentar melden', 'Report comment'),
                  style: _inter.copyWith(color: Colors.white),
                ),
                onTap: () => Navigator.pop(sheetContext, 'report'),
              ),
              if (isOwn)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: Text(
                    t('Kommentar löschen', 'Delete comment'),
                    style: _inter.copyWith(color: Colors.white),
                  ),
                  onTap: () => Navigator.pop(sheetContext, 'delete'),
                ),
            ],
          ),
        );
      },
    );

    if (action == null || !mounted) return;
    if (action == 'delete') {
      await _deleteComment((comment['id'] ?? '').toString());
      return;
    }
    await _reportComment(comment);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    // Neutral dark-grey sheet — kept off the green app tint on purpose so
    // it reads as a separate surface above the feed/leaderboard.
    const darkBg = Color(0xFF161616);
    const cardDark = Color(0xFF1E1E1E);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          minChildSize: 0.45,
          maxChildSize: 0.95,
          builder: (context, scrollController) => Container(
            decoration: BoxDecoration(
              color: darkBg,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              border: Border(
                top: BorderSide(
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              ),
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        t('Kommentare', 'Comments'),
                        style: _inter.copyWith(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: textPrimary,
                          letterSpacing: -0.3,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: textPrimary),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                Divider(
                  color: Colors.white.withValues(alpha: 0.06),
                  height: 1,
                ),
                Expanded(
                  child: _isLoading
                      ? Center(
                          child: CircularProgressIndicator(color: appGreen),
                        )
                      : _comments.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.chat,
                                size: 44,
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                t('Noch keine Kommentare', 'No comments yet'),
                                style: _inter.copyWith(
                                  color: textSecondary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                t(
                                  'Sei der erste – schreib was Nettes.',
                                  'Be the first — say something nice.',
                                ),
                                style: _inter.copyWith(
                                  color: textSecondary.withValues(alpha: 0.65),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.all(16),
                          itemCount: _comments.length,
                          itemBuilder: (context, i) {
                            final comment = _comments[i];
                            final isOwn = comment['is_own'] ?? false;
                            final isLiked = comment['is_liked'] ?? false;
                            final isHighlighted =
                                (comment['id'] ?? '').toString() ==
                                (widget.highlightCommentId ?? '').trim();

                            final username = comment['username'] ?? 'Unknown';
                            final displayName = isOwn
                                ? '$username (${t('Du', 'you')})'
                                : username;

                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onLongPress: () => _showCommentActions(comment),
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Container(
                                  key: _commentKeyFor(
                                    (comment['id'] ?? '').toString(),
                                  ),
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: isHighlighted
                                        ? const Color(0x33FFD54F)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(14),
                                    border: isHighlighted
                                        ? Border.all(
                                            color: const Color(0xFFFFD54F),
                                            width: 1.1,
                                          )
                                        : null,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      GestureDetector(
                                        onTap: comment['avatar'] != null
                                            ? () => showProfilePictureDialog(
                                                context,
                                                comment['avatar'],
                                                username,
                                              )
                                            : null,
                                        child: CircleAvatar(
                                          radius: 16,
                                          backgroundColor: cardDark,
                                          backgroundImage:
                                              comment['avatar'] != null
                                              ? sideQuestCachedImageProvider(
                                                  comment['avatar'],
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
                                          child: comment['avatar'] == null
                                              ? Text(
                                                  username.isNotEmpty
                                                      ? username[0]
                                                            .toUpperCase()
                                                      : 'U',
                                                  style: const TextStyle(
                                                    color: textPrimary,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12,
                                                  ),
                                                )
                                              : null,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onDoubleTap: () {
                                            if (!isLiked) {
                                              _toggleCommentLike(
                                                comment['id'],
                                                false,
                                              );
                                            }
                                          },
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                displayName,
                                                style: _inter.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                  color: textPrimary,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              MentionText(
                                                text: (comment['message'] ?? '')
                                                    .toString(),
                                                style: _inter.copyWith(
                                                  fontSize: 13,
                                                  color: textSecondary,
                                                ),
                                                mentionStyle: _inter.copyWith(
                                                  fontSize: 13,
                                                  color: appGreen,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                                enableProfileNavigation: true,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              GestureDetector(
                                                onTap: () => _toggleCommentLike(
                                                  comment['id'],
                                                  isLiked,
                                                ),
                                                child: Icon(
                                                  isLiked
                                                      ? Icons.favorite
                                                      : Icons.favorite_border,
                                                  color: isLiked
                                                      ? Colors.red
                                                      : textSecondary,
                                                  size: 18,
                                                ),
                                              ),
                                              if (isOwn) ...[
                                                const SizedBox(width: 6),
                                                GestureDetector(
                                                  onTap: () => _deleteComment(
                                                    comment['id'],
                                                  ),
                                                  child: Icon(
                                                    Icons.delete_outline,
                                                    size: 18,
                                                    color: textSecondary,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            (comment['likes_count'] ?? 0)
                                                .toString(),
                                            style: _inter.copyWith(
                                              fontSize: 12,
                                              color: textSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: MentionAutocompleteField(
                          controller: _commentController,
                          style: _inter.copyWith(
                            color: textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.05),
                            hintText: t('Kommentar…', 'Comment…'),
                            hintStyle: _inter.copyWith(
                              color: textSecondary.withValues(alpha: 0.7),
                              fontWeight: FontWeight.w500,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide(
                                color: appGreen.withValues(alpha: 0.6),
                                width: 1.4,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _isSending ? null : _addComment,
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isSending
                                  ? appGreen.withValues(alpha: 0.5)
                                  : appGreen,
                            ),
                            child: Center(
                              child: _isSending
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation(
                                          Color(0xFF0B1108),
                                        ),
                                      ),
                                    )
                                  : const Icon(
                                      Icons.arrow_upward_rounded,
                                      color: Color(0xFF0B1108),
                                      size: 22,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "⋯" on public posts: report the post or block its author (App Store
/// guideline 1.2 needs both for user-generated content). Hidden on own posts.
class _LeaderboardPostMenuButton extends StatelessWidget {
  const _LeaderboardPostMenuButton({
    required this.item,
    required this.size,
    this.overlay = false,
  });

  final Map<String, dynamic> item;
  final double size;

  /// Round, translucent button on top of the photo (like the "Live" badge).
  final bool overlay;

  @override
  Widget build(BuildContext context) {
    final ownerId = (item['user_id'] ?? '').toString();
    final me = Supabase.instance.client.auth.currentUser?.id;
    if (ownerId.isEmpty || ownerId == me) return const SizedBox.shrink();

    final icon = Icon(
      Icons.more_horiz_rounded,
      size: size,
      color: overlay ? Colors.white : const Color(0xFFAAAAAA),
      semanticLabel: t('Mehr', 'More'),
    );
    if (!overlay) {
      return InkResponse(
        radius: size,
        onTap: () => _showActions(context, ownerId),
        child: icon,
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showActions(context, ownerId),
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.34),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: icon,
        ),
      ),
    );
  }

  Future<void> _showActions(BuildContext context, String ownerId) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
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
                t('Post melden', 'Report post'),
                style: _inter.copyWith(color: Colors.white),
              ),
              onTap: () => Navigator.pop(sheetContext, 'report'),
            ),
            ListTile(
              leading: const Icon(Icons.block_rounded, color: Colors.redAccent),
              title: Text(
                t(
                  '${item['username'] ?? 'Nutzer'} blockieren',
                  'Block ${item['username'] ?? 'user'}',
                ),
                style: _inter.copyWith(color: Colors.white),
              ),
              onTap: () => Navigator.pop(sheetContext, 'block'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    void show(String de, String en) =>
        messenger.showSnackBar(SnackBar(content: Text(t(de, en))));

    if (action == 'block') {
      try {
        await BlockService.blockUser(ownerId);
        show(
          'Blockiert. Du siehst die Posts dieser Person nicht mehr.',
          'Blocked. You won\'t see this person\'s posts anymore.',
        );
      } catch (e) {
        AppLogger.warn('Blocking from leaderboard failed: $e');
        show('Blockieren fehlgeschlagen', 'Blocking failed');
      }
      return;
    }

    try {
      final result = await ReportService.submit(
        client: Supabase.instance.client,
        targetType: ReportTargetType.photo,
        photoId: (item['id'] ?? '').toString(),
        reportedUserId: ownerId,
      );
      if (result == ReportSubmissionResult.alreadyReported) {
        show(
          'Du hast diesen Post bereits gemeldet',
          'You already reported this post',
        );
      } else {
        show(
          'Danke! Wir prüfen die Meldung.',
          'Thanks! We will review the report.',
        );
      }
    } catch (e) {
      AppLogger.warn('Reporting leaderboard post failed: $e');
      show('Melden fehlgeschlagen', 'Reporting failed');
    }
  }
}
