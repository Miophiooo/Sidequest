import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../shared.dart';

/// One of the four profile stats: a chip tinted in its own colour
/// (posts green, streak orange, joker gold, duels purple).
class ProfileStatChip extends StatelessWidget {
  final String value;
  final String label;
  final Color accent;
  final IconData icon;

  /// Value > 0 (or duels played): the number takes the accent colour,
  /// otherwise it stays white and the chip a bit more muted.
  final bool active;

  const ProfileStatChip({
    super.key,
    required this.value,
    required this.label,
    required this.accent,
    required this.icon,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final scale = sideQuestResponsiveScale(
      context,
      minScale: 0.72,
      maxScale: 1.0,
    );
    final iconSize = sideQuestResponsiveSize(
      context,
      17,
      minScale: 0.72,
      maxScale: 1.0,
    );
    final valueSize = sideQuestResponsiveSize(
      context,
      22,
      minScale: 0.72,
      maxScale: 1.0,
    );
    final labelSize = sideQuestResponsiveSize(
      context,
      12,
      minScale: 0.72,
      maxScale: 1.0,
    );

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 8 * scale,
        vertical: 11 * scale,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: active ? 0.12 : 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accent.withValues(alpha: active ? 0.42 : 0.22),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: iconSize, color: accent),
                SizedBox(width: 5 * scale),
                Text(
                  value,
                  style: GoogleFonts.inter(
                    fontSize: valueSize,
                    fontWeight: FontWeight.w800,
                    color: active ? accent : Colors.white,
                    height: 1,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 6 * scale),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: GoogleFonts.inter(
                fontSize: labelSize,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.72),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
