import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../shared.dart';

/// "Freund hinzufügen" plus a round share button on the same row, so the
/// friends header doesn't need an extra line for "Meinen Link teilen".
class AddFriendActions extends StatelessWidget {
  const AddFriendActions({
    super.key,
    required this.loading,
    required this.onAdd,
    required this.onShare,
  });

  final bool loading;
  final VoidCallback onAdd;

  /// Gets the share button's context: the share sheet anchors to it (iPad).
  final void Function(BuildContext buttonContext) onShare;

  static const double height = 54;

  @override
  Widget build(BuildContext context) {
    final accentGreen = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: accentGreen,
              disabledBackgroundColor: accentGreen.withValues(alpha: 0.6),
              minimumSize: const Size(double.infinity, height),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
            ),
            onPressed: loading ? null : onAdd,
            child: loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      color: Color(0xFF0B1108),
                      strokeWidth: 2.4,
                    ),
                  )
                : Text(
                    t('Freund hinzufügen', 'Add friend'),
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF0B1108),
                      letterSpacing: 0.2,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 10),
        Builder(
          builder: (buttonContext) => SizedBox.square(
            dimension: height,
            child: IconButton(
              tooltip: t('Meinen Link teilen', 'Share my link'),
              onPressed: () => onShare(buttonContext),
              style: IconButton.styleFrom(
                backgroundColor: accentGreen.withValues(alpha: 0.14),
                side: BorderSide(color: accentGreen.withValues(alpha: 0.55)),
                shape: const CircleBorder(),
              ),
              icon: Icon(Icons.ios_share_rounded, size: 22, color: accentGreen),
            ),
          ),
        ),
      ],
    );
  }
}
