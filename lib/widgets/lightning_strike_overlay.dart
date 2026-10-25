import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const Duration kLightningStrikeDuration = Duration(milliseconds: 720);

/// Big lightning bolt striking across the whole screen (~0.7 s), shown when
/// a duel is sent. Runs in the root overlay above dialogs and never blocks
/// touches. With "reduce motion" only a short flash is shown.
Future<void> showLightningStrike(BuildContext context) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return Future.value();

  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final done = Completer<void>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => LightningStrike(
      reduceMotion: reduceMotion,
      onFinished: () {
        entry.remove();
        if (!done.isCompleted) done.complete();
      },
    ),
  );
  overlay.insert(entry);
  return done.future;
}

class LightningStrike extends StatefulWidget {
  const LightningStrike({
    super.key,
    required this.onFinished,
    this.reduceMotion = false,
    this.seed,
  });

  final VoidCallback onFinished;
  final bool reduceMotion;

  /// Fixes the bolt shape (tests); random otherwise.
  final int? seed;

  @override
  State<LightningStrike> createState() => _LightningStrikeState();
}

class _LightningStrikeState extends State<LightningStrike>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.reduceMotion
        ? const Duration(milliseconds: 260)
        : kLightningStrikeDuration,
  );
  late final int _seed = widget.seed ?? math.Random().nextInt(1 << 30);
  bool _impactFired = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      // Haptic exactly when the bolt hits the bottom.
      if (!_impactFired && _controller.value >= 0.22) {
        _impactFired = true;
        HapticFeedback.heavyImpact();
      }
    });
    _controller.forward().whenComplete(widget.onFinished);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            size: Size.infinite,
            painter: _LightningPainter(
              progress: _controller.value,
              seed: _seed,
              flashOnly: widget.reduceMotion,
            ),
          ),
        ),
      ),
    );
  }
}

class _LightningPainter extends CustomPainter {
  _LightningPainter({
    required this.progress,
    required this.seed,
    required this.flashOnly,
  });

  final double progress;
  final int seed;
  final bool flashOnly;

  // Timeline (fractions of the animation):
  // 0.00-0.22 bolt grows from top to bottom
  // 0.18-0.50 white flash peaks right at the impact
  // 0.22-1.00 bolt flickers twice and fades out
  static const double _strikeEnd = 0.22;

  @override
  void paint(Canvas canvas, Size size) {
    final flash = flashOnly
        ? math.sin(progress * math.pi)
        : _flashIntensity(progress);
    if (flash > 0) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Colors.white.withValues(alpha: 0.32 * flash),
      );
    }
    if (flashOnly) return;

    final reveal = (progress / _strikeEnd).clamp(0.0, 1.0);
    final fade = progress <= _strikeEnd
        ? 1.0
        : 1.0 - ((progress - _strikeEnd) / (1 - _strikeEnd));
    final flicker =
        (progress > 0.38 && progress < 0.44) ||
            (progress > 0.56 && progress < 0.60)
        ? 0.35
        : 1.0;
    final opacity = (fade * flicker).clamp(0.0, 1.0);
    if (opacity <= 0) return;

    final random = math.Random(seed);
    final main = _boltPoints(
      random,
      start: Offset(size.width * (0.42 + random.nextDouble() * 0.2), -10),
      end: Offset(
        size.width * (0.35 + random.nextDouble() * 0.3),
        size.height + 10,
      ),
      segments: 11,
      jitter: size.width * 0.13,
    );
    final branches = <List<Offset>>[
      for (final at in const [0.32, 0.58])
        _boltPoints(
          random,
          start: main[(main.length * at).floor()],
          end:
              main[(main.length * at).floor()] +
              Offset(
                (random.nextBool() ? 1 : -1) * size.width * 0.28,
                size.height * 0.2,
              ),
          segments: 5,
          jitter: size.width * 0.05,
        ),
    ];

    _drawBolt(canvas, main, reveal, opacity, width: 1.0);
    for (final branch in branches) {
      _drawBolt(
        canvas,
        branch,
        (reveal - 0.4) / 0.6,
        opacity * 0.8,
        width: 0.55,
      );
    }
  }

  double _flashIntensity(double p) {
    if (p < 0.18 || p > 0.5) return 0;
    if (p < _strikeEnd) return (p - 0.18) / (_strikeEnd - 0.18);
    return 1 - (p - _strikeEnd) / (0.5 - _strikeEnd);
  }

  List<Offset> _boltPoints(
    math.Random random, {
    required Offset start,
    required Offset end,
    required int segments,
    required double jitter,
  }) {
    final points = <Offset>[start];
    for (var i = 1; i < segments; i++) {
      final t = i / segments;
      final base = Offset.lerp(start, end, t)!;
      points.add(base + Offset((random.nextDouble() * 2 - 1) * jitter, 0));
    }
    points.add(end);
    return points;
  }

  void _drawBolt(
    Canvas canvas,
    List<Offset> points,
    double reveal,
    double opacity, {
    required double width,
  }) {
    if (reveal <= 0 || points.length < 2) return;
    final visible = ((points.length - 1) * reveal.clamp(0.0, 1.0));
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    final full = visible.floor();
    for (var i = 1; i <= full; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    if (full < points.length - 1) {
      final partial = Offset.lerp(
        points[full],
        points[full + 1],
        visible - full,
      )!;
      path.lineTo(partial.dx, partial.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 30 * width
        ..color = const Color(0xFFFFC107).withValues(alpha: 0.45 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 11 * width
        ..color = const Color(0xFFFFE066).withValues(alpha: 0.95 * opacity),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 4 * width
        ..color = Colors.white.withValues(alpha: opacity),
    );
  }

  @override
  bool shouldRepaint(_LightningPainter old) =>
      old.progress != progress ||
      old.seed != seed ||
      old.flashOnly != flashOnly;
}
