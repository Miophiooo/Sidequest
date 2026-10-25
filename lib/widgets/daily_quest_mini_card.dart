import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../features/daily_quest/daily_quest_service.dart';
import '../features/daily_quest/quest_suggestion_sheet.dart';
import '../features/daily_quest/quest_window.dart';
import '../shared.dart';

/// Compact daily-quest banner shown at the top of the Feed and Leaderboard
/// scroll views so the prompt stays visible from anywhere in the app, not just
/// the camera tab.
///
/// Quest text comes from [DailyQuestService] (server rotation with the legacy
/// hardcoded fallback). The 💡 button opens the community quest-suggestion
/// sheet.
class DailyQuestMiniCard extends StatefulWidget {
  const DailyQuestMiniCard({super.key});

  @override
  State<DailyQuestMiniCard> createState() => _DailyQuestMiniCardState();
}

class _DailyQuestMiniCardState extends State<DailyQuestMiniCard> {
  @override
  void initState() {
    super.initState();
    DailyQuestService.revision.addListener(_onQuestChanged);
    DailyQuestService.ensureLoadedForActiveDay();
  }

  @override
  void dispose() {
    DailyQuestService.revision.removeListener(_onQuestChanged);
    super.dispose();
  }

  void _onQuestChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final quest = DailyQuestService.currentForActiveDay();
    final title = t(quest.titleDe, quest.titleEn);
    final description = t(quest.descDe, quest.descEn);
    final author = quest.authorUsername;

    // Two-tone title: first word white, rest in accent green — matches the
    // big camera-screen card's signature look.
    final words = title.trim().split(RegExp(r'\s+'));
    final TextSpan titleSpan;
    if (words.length <= 1) {
      titleSpan = TextSpan(
        text: title,
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          height: 1.1,
        ),
      );
    } else {
      titleSpan = TextSpan(
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          height: 1.1,
        ),
        children: [
          TextSpan(
            text: '${words.first} ',
            style: const TextStyle(color: Colors.white),
          ),
          TextSpan(
            text: words.skip(1).join(' '),
            style: const TextStyle(color: appGreen),
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF1C2620), Color(0xFF13161A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: appGreen.withValues(alpha: 0.55),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: appGreen.withValues(alpha: 0.22),
            blurRadius: 24,
            spreadRadius: -2,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Decorative scattered stars — same subtle flourish the camera-screen
          // card has, just smaller for the compact banner.
          Positioned(
            top: -2,
            left: 4,
            child: Icon(
              Icons.star_rounded,
              size: 9,
              color: const Color(0xFFB39DFF).withValues(alpha: 0.55),
            ),
          ),
          Positioned(
            bottom: 4,
            right: 8,
            child: Icon(
              Icons.star_rounded,
              size: 8,
              color: const Color(0xFFFFC773).withValues(alpha: 0.5),
            ),
          ),
          // Community entry point: suggest your own quest.
          Positioned(
            top: -4,
            right: -6,
            child: IconButton(
              onPressed: () => showQuestSuggestionSheet(context),
              tooltip: t('Quest vorschlagen', 'Suggest a quest'),
              icon: Icon(
                Icons.lightbulb_outline_rounded,
                size: 19,
                color: appGreen.withValues(alpha: 0.85),
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${t('— HEUTIGE QUEST', "— TODAY'S QUEST")} · '
                '${questDurationLabel(questWindowForLondonDay(DailyQuestService.activeLondonDay())).toUpperCase()} —',
                style: GoogleFonts.inter(
                  fontSize: 10,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFFB39DFF),
                ),
              ),
              const SizedBox(height: 5),
              Text.rich(
                titleSpan,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 5),
              Text(
                description,
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFB8B8B8),
                  height: 1.3,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (author != null) ...[
                const SizedBox(height: 6),
                Text(
                  t('💡 Quest von @$author', '💡 Quest by @$author'),
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: appGreen.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
