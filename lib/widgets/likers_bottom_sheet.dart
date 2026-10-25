import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../profile.dart';
import '../shared.dart';

/// Opens an Instagram-style bottom sheet listing every user who liked the
/// given photo. Avatar + username; tap a row to jump to that user's profile.
///
/// `onOpenOwnProfile` lets the caller route to the profile *tab* (preserving
/// the bottom navigation bar) when the user taps their own row, instead of
/// pushing a fullscreen ProfileScreen route that hides the nav and traps the
/// back gesture.
Future<void> showLikersBottomSheet(
  BuildContext context,
  String photoId, {
  VoidCallback? onOpenOwnProfile,
}) async {
  if (photoId.isEmpty) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _LikersSheet(
      photoId: photoId,
      onOpenOwnProfile: onOpenOwnProfile,
    ),
  );
}

class _LikersSheet extends StatefulWidget {
  final String photoId;
  final VoidCallback? onOpenOwnProfile;
  const _LikersSheet({required this.photoId, this.onOpenOwnProfile});

  @override
  State<_LikersSheet> createState() => _LikersSheetState();
}

class _LikersSheetState extends State<_LikersSheet> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadLikers();
  }

  Future<List<Map<String, dynamic>>> _loadLikers() async {
    final client = Supabase.instance.client;
    // One round-trip: pull likes for this photo joined with each liker's
    // public profile fields.
    final rows = await client
        .from('likes')
        .select('user_id, created_at, users_profile(id, username, profile_picture)')
        .eq('photo_id', widget.photoId)
        .order('created_at', ascending: false);

    return (rows as List)
        .map<Map<String, dynamic>>(
          (row) => Map<String, dynamic>.from(row as Map),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    const sheetBg = Color(0xFF121212);
    const textPrimary = Colors.white;
    const textSecondary = Color(0xFFAAAAAA);
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: sheetBg,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      t('Gefällt', 'Liked by'),
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: textPrimary,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: textPrimary),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(color: Color(0xFF2A2A2A), height: 1),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(color: appGreen),
                      );
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            t(
                              'Konnte Likes nicht laden',
                              'Could not load likes',
                            ),
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: textSecondary,
                            ),
                          ),
                        ),
                      );
                    }
                    final likers = snapshot.data ?? const [];
                    if (likers.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            t('Noch keine Likes', 'No likes yet'),
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: textSecondary,
                            ),
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      controller: scrollController,
                      padding: EdgeInsets.fromLTRB(8, 4, 8, 16 + safeBottom),
                      itemCount: likers.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: 2),
                      itemBuilder: (context, i) {
                        final liker = likers[i];
                        final profileRaw = liker['users_profile'];
                        final profile = (profileRaw is Map)
                            ? Map<String, dynamic>.from(profileRaw)
                            : const <String, dynamic>{};
                        final userId = (profile['id'] ?? liker['user_id'] ?? '')
                            .toString();
                        final username = (profile['username'] ?? 'Unknown')
                            .toString();
                        final pic = (profile['profile_picture'] ?? '')
                            .toString()
                            .trim();

                        final currentUserId = Supabase
                            .instance
                            .client
                            .auth
                            .currentUser
                            ?.id;
                        final isOwnRow =
                            currentUserId != null && userId == currentUserId;

                        return InkWell(
                          onTap: userId.isEmpty
                              ? null
                              : () {
                                  Navigator.pop(context);
                                  if (isOwnRow) {
                                    // Switch to the profile *tab* so the
                                    // bottom nav stays active and back nav
                                    // keeps working.
                                    widget.onOpenOwnProfile?.call();
                                    return;
                                  }
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ProfileScreen(userId: userId),
                                    ),
                                  );
                                },
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor: const Color(0xFF1E1E1E),
                                  backgroundImage: pic.isNotEmpty
                                      ? sideQuestCachedImageProvider(
                                          pic,
                                          cacheWidth: sideQuestCacheWidth(
                                            context,
                                            40,
                                          ),
                                          cacheHeight: sideQuestCacheWidth(
                                            context,
                                            40,
                                          ),
                                        )
                                      : null,
                                  child: pic.isEmpty
                                      ? Text(
                                          username.isNotEmpty
                                              ? username[0].toUpperCase()
                                              : '?',
                                          style: GoogleFonts.inter(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    isOwnRow
                                        ? '$username (${t('Du', 'you')})'
                                        : username,
                                    style: GoogleFonts.inter(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
