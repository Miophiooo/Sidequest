import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../shared.dart';
import 'invite_share.dart';

/// Number of friends after which the nudge to invite people disappears.
const int kInviteFriendGoal = 3;

/// "Invite 3 friends" card with progress, shown until the user has
/// [kInviteFriendGoal] friends. Sharing sends the personal invite link, so
/// whoever opens it sends a friend request right away.
class InviteProgressCard extends StatelessWidget {
  const InviteProgressCard({
    super.key,
    required this.friendCount,
    required this.surface,
    this.compact = false,
  });

  final int friendCount;

  /// Analytics label of the place the card is shown.
  final String surface;

  /// Without the explanation text (when the screen already explains it).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final done = friendCount.clamp(0, kInviteFriendGoal);
    final missing = kInviteFriendGoal - done;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [Color(0xFF1C2620), Color(0xFF13161A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: appGreen.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t(
                    'Lade $kInviteFriendGoal Freunde ein',
                    'Invite $kInviteFriendGoal friends',
                  ),
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
              Semantics(
                label: t(
                  '$done von $kInviteFriendGoal Freunden',
                  '$done of $kInviteFriendGoal friends',
                ),
                child: Row(
                  children: [
                    for (var i = 0; i < kInviteFriendGoal; i++)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        width: 26,
                        height: 26,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < done
                              ? appGreen
                              : Colors.white.withValues(alpha: 0.06),
                          border: Border.all(
                            color: i < done
                                ? appGreen
                                : Colors.white.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Icon(
                          i < done ? Icons.check_rounded : Icons.person_rounded,
                          size: 15,
                          color: i < done
                              ? const Color(0xFF10160F)
                              : Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (!compact) ...[
            const SizedBox(height: 6),
            Text(
              done == 0
                  ? t(
                      'SideQuest macht erst mit deinen Leuten Spaß. Wer deinen Link öffnet, schickt dir direkt eine Anfrage.',
                      'SideQuest only gets fun with your people. Whoever opens your link sends you a request right away.',
                    )
                  : t(
                      missing == 1
                          ? 'Noch 1 Freund – dann geht es richtig los.'
                          : 'Noch $missing Freunde – dann geht es richtig los.',
                      missing == 1
                          ? 'One more friend and it really gets going.'
                          : '$missing more friends and it really gets going.',
                    ),
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: const Color(0xFFB8B8B8),
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: Builder(
              builder: (buttonContext) => FilledButton.icon(
                onPressed: () => shareSideQuestInvite(
                  surface: surface,
                  context: buttonContext,
                ),
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: Text(
                  t('Einladungslink teilen', 'Share invite link'),
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: appGreen,
                  foregroundColor: const Color(0xFF10160F),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
