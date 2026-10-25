import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

const sideQuestInk = Color(0xFF101714);
const sideQuestCream = Color(0xFFF6F4ED);
const sideQuestLeaf = Color(0xFF7DB56A);
const sideQuestMoss = Color(0xFF45684A);

class SideQuestLogo extends StatelessWidget {
  final double size;
  final bool elevated;

  const SideQuestLogo({super.key, this.size = 96, this.elevated = true});

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.28;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [sideQuestInk, sideQuestMoss],
        ),
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: sideQuestInk.withValues(alpha: 0.22),
                  blurRadius: size * 0.18,
                  offset: Offset(0, size * 0.08),
                ),
              ]
            : null,
      ),
      child: Stack(
        children: [
          Positioned(
            top: size * 0.14,
            left: size * 0.16,
            right: size * 0.16,
            child: Container(
              height: size * 0.19,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(size * 0.3),
                  topRight: Radius.circular(size * 0.3),
                ),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.82),
                    width: size * 0.05,
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: size * 0.54,
              height: size * 0.38,
              decoration: BoxDecoration(
                color: sideQuestCream,
                borderRadius: BorderRadius.circular(size * 0.13),
              ),
            ),
          ),
          Center(
            child: Container(
              width: size * 0.23,
              height: size * 0.23,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFAAD68F),
              ),
            ),
          ),
          Positioned(
            top: size * 0.2,
            right: size * 0.18,
            child: Transform.rotate(
              angle: 0.78,
              child: Container(
                width: size * 0.12,
                height: size * 0.12,
                decoration: BoxDecoration(
                  color: const Color(0xFFAAD68F),
                  borderRadius: BorderRadius.circular(size * 0.025),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: size * 0.18,
            left: size * 0.24,
            right: size * 0.24,
            child: Container(
              height: size * 0.07,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size),
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0.0),
                    Colors.white.withValues(alpha: 0.72),
                    const Color(0xFFAAD68F),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SideQuestWordmark extends StatelessWidget {
  final double fontSize;
  final Color color;
  final double letterSpacing;

  const SideQuestWordmark({
    super.key,
    this.fontSize = 40,
    this.color = sideQuestInk,
    this.letterSpacing = 1.4,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      'SIDEQUEST',
      textAlign: TextAlign.center,
      style: GoogleFonts.inter(
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
        letterSpacing: letterSpacing,
        color: color,
      ),
    );
  }
}
