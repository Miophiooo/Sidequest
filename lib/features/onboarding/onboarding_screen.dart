import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../shared.dart';
import '../daily_quest/daily_quest_service.dart';
import '../invite/invite_progress_card.dart';

/// What the user picked on the last onboarding page, so [MainTabs] can react
/// (e.g. jump straight to the friends tab).
enum OnboardingResult { done, openFriends }

/// Full-screen, swipeable 3-page intro shown exactly once after account
/// creation (guarded by `users_profile.onboarding_completed`).
///
/// Page 1: why SideQuest exists (go outside, catch the moment).
/// Page 2: today's live quest + streak/joker basics.
/// Page 3: friends — the app only sparks with people you know.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _page = 0;

  static const int _pageCount = 3;

  @override
  void initState() {
    super.initState();
    // Page 2 shows the real quest of the day — kick off the server load now
    // so it's there by the time the user swipes.
    DailyQuestService.ensureLoadedForActiveDay();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _next() {
    HapticFeedback.selectionClick();
    if (_page >= _pageCount - 1) {
      Navigator.of(context).pop(OnboardingResult.done);
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _finishToFriends() {
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(OnboardingResult.openFriends);
  }

  TextSpan _twoToneTitle(String title) {
    final words = title.trim().split(RegExp(r'\s+'));
    final style = GoogleFonts.nunito(
      fontSize: 30,
      fontWeight: FontWeight.w900,
      height: 1.05,
      letterSpacing: -0.5,
    );
    if (words.length <= 1) {
      return TextSpan(
        text: title,
        style: style.copyWith(color: Colors.white),
      );
    }
    return TextSpan(
      style: style,
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

  Widget _heroEmoji(String emoji) {
    return Container(
      width: 110,
      height: 110,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFF1C2620), Color(0xFF13161A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: appGreen.withValues(alpha: 0.5), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: appGreen.withValues(alpha: 0.25),
            blurRadius: 36,
            spreadRadius: -4,
          ),
        ],
      ),
      child: Text(emoji, style: const TextStyle(fontSize: 52)),
    );
  }

  Widget _bulletRow(String emoji, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                color: const Color(0xFFC9C9C9),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pageShell({
    required String heroEmoji,
    required String title,
    required String subtitle,
    required List<Widget> body,
  }) {
    // Scrolls instead of overflowing on small phones; the spacers still
    // spread the content on tall ones.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 12),
          child: IntrinsicHeight(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(flex: 2),
                Center(child: _heroEmoji(heroEmoji)),
                const Spacer(flex: 2),
                Text.rich(_twoToneTitle(title)),
                const SizedBox(height: 10),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.75),
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 18),
                ...body,
                const Spacer(flex: 3),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIntroPage() {
    return _pageShell(
      heroEmoji: '🧭',
      title: t('Willkommen bei SideQuest', 'Welcome to SideQuest'),
      subtitle: t(
        'Jeden Tag eine Quest. Geh raus, fang den Moment ein, zeig ihn deinen Freunden.',
        'One quest every day. Go outside, catch the moment, show your friends.',
      ),
      body: [
        _bulletRow(
          '⏰',
          t(
            'Die Quest startet jeden Tag zu einer anderen Uhrzeit — du erfährst es per Push.',
            'The quest drops at a different time each day — you get a push when it starts.',
          ),
        ),
        _bulletRow(
          '📸',
          t(
            'Kein Filter-Theater: ein echtes Foto, direkt aus dem Moment.',
            'No filter theater: one real photo, straight from the moment.',
          ),
        ),
        _bulletRow(
          '🌍',
          t(
            'Erst wenn du gepostet hast, siehst du die Fotos der anderen.',
            'You only see everyone else\'s photos after you post yours.',
          ),
        ),
      ],
    );
  }

  Widget _buildQuestPage() {
    final quest = DailyQuestService.currentForActiveDay();
    return _pageShell(
      heroEmoji: quest.emoji,
      title: t('Deine heutige Quest', 'Today\'s quest for you'),
      subtitle: t(
        'So sieht eine Quest aus — diese hier läuft gerade wirklich:',
        'This is what a quest looks like — this one is live right now:',
      ),
      body: [
        Container(
          width: double.infinity,
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
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('— HEUTIGE QUEST —', "— TODAY'S QUEST —"),
                style: GoogleFonts.inter(
                  fontSize: 10,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFFB39DFF),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                t(quest.titleDe, quest.titleEn),
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                t(quest.descDe, quest.descEn),
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFB8B8B8),
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _bulletRow(
          '🔥',
          t(
            'Poste im Zeitfenster und deine Streak wächst Tag für Tag.',
            'Post inside the time window and your streak grows day by day.',
          ),
        ),
        _bulletRow(
          '🃏',
          t(
            'Verpasst du mal eine Quest, rettet ein Joker automatisch deine Streak — Joker verdienst du in Duellen.',
            'Miss a quest and a joker saves your streak automatically — earn jokers in duels.',
          ),
        ),
      ],
    );
  }

  Widget _buildFriendsPage() {
    return _pageShell(
      heroEmoji: '🤝',
      title: t('Mit Freunden zündet es', 'It sparks with friends'),
      subtitle: t(
        'SideQuest lebt von den Reaktionen deiner Leute. Hol sie rein — der Rest ergibt sich.',
        'SideQuest runs on reactions from your people. Get them in — the rest follows.',
      ),
      body: [
        _bulletRow(
          '⚔️',
          t(
            'Fordere Freunde zu Foto-Duellen heraus und sammle Joker.',
            'Challenge friends to photo duels and collect jokers.',
          ),
        ),
        _bulletRow(
          '💡',
          t(
            'Schlag eigene Quests vor — die besten landen mit deinem Namen in der Rotation.',
            'Suggest your own quests — the best ones enter the rotation with your name on them.',
          ),
        ),
        const SizedBox(height: 14),
        // The step that matters most: without friends nobody comes back.
        const InviteProgressCard(
          friendCount: 0,
          surface: 'onboarding',
          compact: true,
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _finishToFriends,
            icon: const Icon(Icons.people_rounded, size: 19, color: appGreen),
            label: Text(
              t('Freunde finden', 'Find friends'),
              style: GoogleFonts.inter(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: appGreen,
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: appGreen.withValues(alpha: 0.6)),
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
    final isLastPage = _page == _pageCount - 1;

    return PopScope(
      // The intro is one-shot; backing out counts as "done" so we never
      // trap the user. The completion flag is set by the caller either way.
      canPop: true,
      child: Scaffold(
        backgroundColor: const Color(0xFF101413),
        body: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6, right: 12),
                  child: TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(OnboardingResult.done),
                    child: Text(
                      t('Überspringen', 'Skip'),
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (value) => setState(() => _page = value),
                  children: [
                    _buildIntroPage(),
                    _buildQuestPage(),
                    _buildFriendsPage(),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 22),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(_pageCount, (i) {
                        final active = i == _page;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOut,
                          margin: const EdgeInsets.symmetric(horizontal: 3.5),
                          width: active ? 22 : 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: active
                                ? appGreen
                                : Colors.white.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton(
                        onPressed: _next,
                        style: FilledButton.styleFrom(
                          backgroundColor: appGreen,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                        child: Text(
                          isLastPage
                              ? t('Los geht\'s! 🚀', 'Let\'s go! 🚀')
                              : t('Weiter', 'Next'),
                          style: GoogleFonts.inter(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF10160F),
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
    );
  }
}
