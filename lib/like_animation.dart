import 'package:flutter/material.dart';
import 'dart:math';

class LikeAnimation extends StatefulWidget {
  final Widget child;
  final bool isAnimating;
  final VoidCallback? onEnd;
  final bool showParticles;
  final bool isDislike;

  const LikeAnimation({
    super.key,
    required this.child,
    required this.isAnimating,
    this.onEnd,
    this.showParticles = true,
    this.isDislike = false,
  });

  @override
  State<LikeAnimation> createState() => _LikeAnimationState();
}

class _LikeAnimationState extends State<LikeAnimation> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  final List<Particle> _particles = [];
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.4).chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.4, end: 1.0).chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_controller);

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onEnd?.call();
      }
    });
  }

  @override
  void didUpdateWidget(LikeAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isAnimating && !oldWidget.isAnimating) {
      _startAnimation();
    }
  }

  void _startAnimation() {
    _controller.reset();
    _controller.forward();
    
    if (widget.showParticles) {
      _generateParticles();
    }
  }

  void _generateParticles() {
    setState(() {
      _particles.clear();
      for (int i = 0; i < 8; i++) {
        final angle = (i * 45) * (pi / 180);
        _particles.add(Particle(
          angle: angle,
          distance: 30.0 + _random.nextDouble() * 20,
          duration: 500 + _random.nextInt(200),
          delay: _random.nextInt(50),
        ));
      }
    });

    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() => _particles.clear());
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Particles
        ..._particles.map((particle) => AnimatedParticle(particle: particle, isDislike: widget.isDislike)),
        
        // Main animated widget
        ScaleTransition(
          scale: _scaleAnimation,
          child: widget.child,
        ),
      ],
    );
  }
}

class Particle {
  final double angle;
  final double distance;
  final int duration;
  final int delay;

  Particle({
    required this.angle,
    required this.distance,
    required this.duration,
    required this.delay,
  });
}

class AnimatedParticle extends StatefulWidget {
  final Particle particle;
  final bool isDislike;

  const AnimatedParticle({super.key, required this.particle, this.isDislike = false});

  @override
  State<AnimatedParticle> createState() => _AnimatedParticleState();
}

class _AnimatedParticleState extends State<AnimatedParticle> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _moveAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: Duration(milliseconds: widget.particle.duration),
      vsync: this,
    );

    _moveAnimation = Tween<double>(begin: 0.0, end: widget.particle.distance).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _fadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.5, 1.0, curve: Curves.easeIn)),
    );

    Future.delayed(Duration(milliseconds: widget.particle.delay), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: widget.isDislike
            ? Text(
                '💩',
                style: const TextStyle(fontSize: 12),
              )
            : Icon(
                Icons.favorite,
                color: Colors.red,
                size: 12,
              ),
      ),
      builder: (context, child) {
        final x = _moveAnimation.value * cos(widget.particle.angle);
        final y = _moveAnimation.value * sin(widget.particle.angle);

        return Transform.translate(
          offset: Offset(x, y),
          child: child,
        );
      },
    );
  }
}
