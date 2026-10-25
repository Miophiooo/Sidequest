import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/app_logger.dart';
import '../../shared.dart';
import 'quest_suggestion_sheet.dart';

const Color _lavender = Color(0xFFB39DFF);

class QuestSuggestionBoardEntry {
  final String id;
  final String title;
  final String description;
  final String authorUsername;
  int upvotes;
  int downvotes;
  int myVote;

  QuestSuggestionBoardEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.authorUsername,
    required this.upvotes,
    required this.downvotes,
    required this.myVote,
  });

  int get score => upvotes - downvotes;

  static QuestSuggestionBoardEntry? fromRow(Map<String, dynamic> row) {
    final id = (row['id'] ?? '').toString();
    final title = (row['title'] ?? '').toString().trim();
    if (id.isEmpty || title.isEmpty) return null;
    return QuestSuggestionBoardEntry(
      id: id,
      title: title,
      description: (row['description'] ?? '').toString().trim(),
      authorUsername: (row['author_username'] ?? '?').toString(),
      upvotes: (row['upvotes'] as num?)?.toInt() ?? 0,
      downvotes: (row['downvotes'] as num?)?.toInt() ?? 0,
      myVote: (row['my_vote'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Community quest board for the leaderboard tab: users submit quest ideas
/// and vote on them. Votes pre-sort the review queue — going live still
/// requires manual approval (`approve_quest_suggestion`), so nothing reaches
/// the rotation unmoderated.
class QuestSuggestionBoard extends StatefulWidget {
  const QuestSuggestionBoard({super.key});

  @override
  State<QuestSuggestionBoard> createState() => _QuestSuggestionBoardState();
}

class _QuestSuggestionBoardState extends State<QuestSuggestionBoard> {
  static const int _previewCount = 3;

  List<QuestSuggestionBoardEntry> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client.rpc(
        'get_quest_suggestion_board',
        params: {'p_limit': 50},
      );
      if (!mounted) return;
      final entries = <QuestSuggestionBoardEntry>[];
      if (rows is List) {
        for (final row in rows) {
          if (row is! Map) continue;
          final entry = QuestSuggestionBoardEntry.fromRow(
            Map<String, dynamic>.from(row),
          );
          if (entry != null) entries.add(entry);
        }
      }
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      AppLogger.debug('Quest board load failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _vote(QuestSuggestionBoardEntry entry, int value) async {
    HapticFeedback.selectionClick();
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    final previousVote = entry.myVote;
    final newVote = previousVote == value ? 0 : value;

    // Optimistic update; reload from server on failure.
    setState(() {
      if (previousVote == 1) entry.upvotes--;
      if (previousVote == -1) entry.downvotes--;
      if (newVote == 1) entry.upvotes++;
      if (newVote == -1) entry.downvotes++;
      entry.myVote = newVote;
      _entries = List.of(_entries)
        ..sort((a, b) => b.score.compareTo(a.score));
    });

    try {
      if (newVote == 0) {
        await client
            .from('quest_suggestion_votes')
            .delete()
            .eq('suggestion_id', entry.id)
            .eq('user_id', userId);
      } else {
        await client.from('quest_suggestion_votes').upsert({
          'suggestion_id': entry.id,
          'user_id': userId,
          'value': newVote,
        });
      }
    } catch (e) {
      AppLogger.debug('Quest vote failed: $e');
      await _load();
    }
  }

  Future<void> _openSuggestionSheet() async {
    await showQuestSuggestionSheet(context);
    // A fresh suggestion may have landed — refresh the board.
    await _load();
  }

  void _showFullBoard() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF161A18),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              child: StatefulBuilder(
                builder: (context, setSheetState) {
                  return Column(
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        t(
                          '💡 Alle Quest-Ideen',
                          '💡 All quest ideas',
                        ),
                        style: GoogleFonts.inter(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: ListView.separated(
                          controller: scrollController,
                          itemCount: _entries.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            return _SuggestionTile(
                              entry: _entries[i],
                              onVote: (value) async {
                                await _vote(_entries[i], value);
                                setSheetState(() {});
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = _entries.take(_previewCount).toList(growable: false);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF1D1A26), Color(0xFF13141A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: _lavender.withValues(alpha: 0.45), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t(
                    '— QUEST-IDEEN DER COMMUNITY —',
                    '— COMMUNITY QUEST IDEAS —',
                  ),
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    letterSpacing: 1.0,
                    fontWeight: FontWeight.w800,
                    color: _lavender,
                  ),
                ),
              ),
              GestureDetector(
                onTap: _openSuggestionSheet,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _lavender.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _lavender.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    t('💡 Vorschlagen', '💡 Suggest'),
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: _lavender,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _lavender.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            )
          else if (_entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                t(
                  'Noch keine Ideen. Reich die erste ein — die besten landen mit deinem Namen in der Rotation!',
                  'No ideas yet. Submit the first one — the best make the rotation with your name on them!',
                ),
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFB8B8B8),
                  height: 1.35,
                ),
              ),
            )
          else ...[
            for (var i = 0; i < preview.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _SuggestionTile(entry: preview[i], onVote: (value) => _vote(preview[i], value)),
            ],
            if (_entries.length > _previewCount) ...[
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  onPressed: _showFullBoard,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(
                    t(
                      'Alle ${_entries.length} Ideen ansehen',
                      'See all ${_entries.length} ideas',
                    ),
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _lavender.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  final QuestSuggestionBoardEntry entry;
  final ValueChanged<int> onVote;

  const _SuggestionTile({required this.entry, required this.onVote});

  Widget _voteButton({
    required IconData icon,
    required int count,
    required bool active,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    final color = active ? activeColor : Colors.white.withValues(alpha: 0.45);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 3),
            Text(
              '$count',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 9, 8, 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  entry.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFFAAAAAA),
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '@${entry.authorUsername}',
                  style: GoogleFonts.inter(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: _lavender.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _voteButton(
            icon: Icons.keyboard_arrow_up_rounded,
            count: entry.upvotes,
            active: entry.myVote == 1,
            activeColor: appGreen,
            onTap: () => onVote(1),
          ),
          _voteButton(
            icon: Icons.keyboard_arrow_down_rounded,
            count: entry.downvotes,
            active: entry.myVote == -1,
            activeColor: const Color(0xFFFF6B6B),
            onTap: () => onVote(-1),
          ),
        ],
      ),
    );
  }
}
