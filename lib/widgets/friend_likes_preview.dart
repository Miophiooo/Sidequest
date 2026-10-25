import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../shared.dart';
import 'likers_bottom_sheet.dart';

/// Instagram-style "Liked by your friends" preview that overlays the
/// bottom-left of a feed post: up to 3 small friend avatars stacked with a
/// small heart marker on each.
///
/// Renders nothing when no friends of the current user have liked the post.
/// Optionally hides itself while [hiddenListenable] is `true` so the parent
/// card can tuck it away during a long-press / image-preview gesture.
class FriendLikesPreview extends StatefulWidget {
  final String photoId;
  final ValueListenable<bool>? hiddenListenable;

  const FriendLikesPreview({
    super.key,
    required this.photoId,
    this.hiddenListenable,
  });

  @override
  State<FriendLikesPreview> createState() => _FriendLikesPreviewState();
}

class _FriendLikesPreviewState extends State<FriendLikesPreview> {
  // The feed builds cards two screens ahead and drops them again, so without
  // these caches every scroll fired two requests per card (one of them the
  // full friends list, identical for every card).
  static const Duration _friendIdsTtl = Duration(minutes: 5);
  static const Duration _likersTtl = Duration(minutes: 2);
  static String? _friendIdsUser;
  static DateTime? _friendIdsLoadedAt;
  static Future<Set<String>>? _friendIdsFuture;
  static final Map<String, (DateTime, List<_LikerProfile>)> _likersByPhoto = {};

  Future<List<_LikerProfile>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _cachedOrLoad();
  }

  @override
  void didUpdateWidget(covariant FriendLikesPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoId != widget.photoId) {
      _future = _cachedOrLoad();
    }
  }

  List<_LikerProfile>? get _cachedLikers => _likersByPhoto[widget.photoId]?.$2;

  Future<List<_LikerProfile>> _cachedOrLoad() {
    final cached = _likersByPhoto[widget.photoId];
    if (cached != null && DateTime.now().difference(cached.$1) < _likersTtl) {
      return Future.value(cached.$2);
    }
    final photoId = widget.photoId;
    return _load().then((likers) {
      _likersByPhoto[photoId] = (DateTime.now(), likers);
      return likers;
    });
  }

  static Future<Set<String>> _friendIds(SupabaseClient client, String me) {
    final loadedAt = _friendIdsLoadedAt;
    final fresh =
        _friendIdsUser == me &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < _friendIdsTtl;
    if (fresh && _friendIdsFuture != null) return _friendIdsFuture!;

    _friendIdsUser = me;
    _friendIdsLoadedAt = DateTime.now();
    final future = () async {
      // status='accepted' on either side of the row.
      final friendships = await client
          .from('friends')
          .select('user_id, friend_id')
          .or('user_id.eq.$me,friend_id.eq.$me')
          .eq('status', 'accepted');
      final ids = <String>{};
      for (final row in friendships) {
        final a = (row['user_id'] ?? '').toString();
        final b = (row['friend_id'] ?? '').toString();
        if (a == me && b.isNotEmpty) ids.add(b);
        if (b == me && a.isNotEmpty) ids.add(a);
      }
      return ids;
    }();
    // A failed load must not stick for 5 minutes.
    future.catchError((Object _) {
      _friendIdsFuture = null;
      _friendIdsLoadedAt = null;
      return <String>{};
    });
    return _friendIdsFuture = future;
  }

  Future<List<_LikerProfile>> _load() async {
    final client = Supabase.instance.client;
    final me = client.auth.currentUser?.id;
    if (me == null || me.isEmpty || widget.photoId.isEmpty) {
      return const [];
    }

    // Step 1 — friend ids (cached, shared by all cards).
    final friendIds = await _friendIds(client, me);
    if (friendIds.isEmpty) return const [];

    // Step 2 — most recent 3 likes on this photo by those friend ids.
    final likes = await client
        .from('likes')
        .select(
          'user_id, created_at, users_profile(id, username, profile_picture)',
        )
        .eq('photo_id', widget.photoId)
        .inFilter('user_id', friendIds.toList())
        .order('created_at', ascending: false)
        .limit(3);

    return (likes as List)
        .map<_LikerProfile?>((raw) {
          final row = Map<String, dynamic>.from(raw as Map);
          final profileRaw = row['users_profile'];
          if (profileRaw is! Map) return null;
          final profile = Map<String, dynamic>.from(profileRaw);
          return _LikerProfile(
            userId: (profile['id'] ?? '').toString(),
            username: (profile['username'] ?? '').toString(),
            profilePicture: (profile['profile_picture'] ?? '')
                .toString()
                .trim(),
          );
        })
        .whereType<_LikerProfile>()
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_LikerProfile>>(
      future: _future,
      initialData: _cachedLikers,
      builder: (context, snapshot) {
        final likers = snapshot.data ?? const <_LikerProfile>[];
        if (likers.isEmpty) return const SizedBox.shrink();

        final photoId = widget.photoId;
        final stack = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showLikersBottomSheet(context, photoId),
          child: _AvatarStack(likers: likers),
        );

        final hiddenListenable = widget.hiddenListenable;
        if (hiddenListenable == null) {
          return stack;
        }
        return ValueListenableBuilder<bool>(
          valueListenable: hiddenListenable,
          builder: (_, hidden, _) {
            return AnimatedOpacity(
              opacity: hidden ? 0 : 1,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: IgnorePointer(ignoring: hidden, child: stack),
            );
          },
        );
      },
    );
  }
}

class _LikerProfile {
  final String userId;
  final String username;
  final String profilePicture;

  const _LikerProfile({
    required this.userId,
    required this.username,
    required this.profilePicture,
  });
}

class _AvatarStack extends StatelessWidget {
  final List<_LikerProfile> likers;

  const _AvatarStack({required this.likers});

  @override
  Widget build(BuildContext context) {
    // Instagram-style row: avatars sit side-by-side with a small gap (no
    // overlap) so each face is fully visible, and each carries a heart pinned
    // to its bottom-right corner.
    const avatarSize = 36.0;
    const gap = 6.0;
    final width = avatarSize * likers.length + gap * (likers.length - 1) + 6;
    return SizedBox(
      width: width,
      height: avatarSize + 6,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (int i = 0; i < likers.length; i++)
            Positioned(
              left: i * (avatarSize + gap),
              top: 0,
              child: _AvatarWithHeart(liker: likers[i], size: avatarSize),
            ),
        ],
      ),
    );
  }
}

class _AvatarWithHeart extends StatelessWidget {
  final _LikerProfile liker;
  final double size;

  const _AvatarWithHeart({required this.liker, required this.size});

  @override
  Widget build(BuildContext context) {
    final pic = liker.profilePicture;
    return SizedBox(
      width: size + 6,
      height: size + 6,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Avatar with a dark ring so adjacent avatars read as separate
          // circles even when they overlap on top of a busy photo.
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF111111), width: 2),
              color: const Color(0xFF1E1E1E),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipOval(child: _avatarChild(context, pic)),
          ),
          // Heart marker pinned snug to the avatar's bottom-right corner.
          Positioned(
            right: 2,
            bottom: 0,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF111111), width: 1.6),
              ),
              child: const Icon(Icons.favorite, size: 11, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatarChild(BuildContext context, String pic) {
    if (pic.isEmpty) return _initialFallback();
    final cacheSize = sideQuestCacheWidth(context, size);
    final provider = sideQuestCachedImageProvider(
      pic,
      cacheWidth: cacheSize,
      cacheHeight: cacheSize,
    );
    if (provider == null) return _initialFallback();
    return Image(
      image: provider,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => _initialFallback(),
    );
  }

  Widget _initialFallback() {
    return Center(
      child: Text(
        liker.username.isNotEmpty ? liker.username[0].toUpperCase() : '?',
        style: GoogleFonts.inter(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}
