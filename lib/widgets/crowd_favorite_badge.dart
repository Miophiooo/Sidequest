import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../shared.dart';

const Color _gold = Color(0xFFFFC14D);

/// True while the Crowd Favorite title from the last win is still active.
bool crowdFavoriteActive(dynamic activeUntil, [DateTime? now]) {
  final until = parseUtcTimestamp(activeUntil);
  if (until == null) return false;
  return until.isAfter((now ?? DateTime.now()).toUtc());
}

/// "👑 Crowd Favorite ×N" on the profile once the user has won the daily
/// title. Glows gold while the latest title is active.
class CrowdFavoriteBadge extends StatelessWidget {
  const CrowdFavoriteBadge({
    super.key,
    required this.count,
    required this.active,
  });

  final int count;
  final bool active;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final label = active
        ? t('Crowd Favorite des Tages', 'Crowd Favorite of the day')
        : 'Crowd Favorite';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: active
            ? const LinearGradient(
                colors: [Color(0xFF5A3E00), Color(0xFF8A6100)],
              )
            : null,
        color: active ? null : _gold.withValues(alpha: 0.10),
        border: Border.all(
          color: _gold.withValues(alpha: active ? 0.95 : 0.45),
          width: 1.2,
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.35),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('👑', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                color: active ? Colors.white : _gold,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (count > 1) ...[
            const SizedBox(width: 8),
            Text(
              '×$count',
              style: GoogleFonts.inter(
                color: _gold,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
