import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'concert_after_palette.dart';

/// Decorative paper only; never participates in the scrapbook gestures.
class ScrapbookPageBackground extends StatelessWidget {
  const ScrapbookPageBackground({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _PaperPainter(PosterMoodScope.of(context)),
        size: Size.infinite,
      ),
    ),
  );
}

/// 공연 후 페이지의 크라프트지 질감만 얹는 공통 오버레이입니다.
/// 페이지 색과 본문은 유지하고, 섬유·펄프·가장자리 얼룩만 추가합니다.
class ScrapbookPaperTextureOverlay extends StatelessWidget {
  final double opacity;
  final int seed;

  const ScrapbookPaperTextureOverlay({
    super.key,
    this.opacity = 1,
    this.seed = 73,
  });

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _PaperTextureOverlayPainter(opacity: opacity, seed: seed),
        size: Size.infinite,
      ),
    ),
  );
}

class _PaperTextureOverlayPainter extends CustomPainter {
  final double opacity;
  final int seed;

  const _PaperTextureOverlayPainter({
    required this.opacity,
    required this.seed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || opacity <= 0) return;
    final bounds = Offset.zero & size;
    final random = math.Random(seed);
    final paint = Paint();

    canvas.save();
    canvas.clipRect(bounds);

    for (var i = 0; i < 18; i++) {
      final center = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final radius = size.shortestSide * (0.10 + random.nextDouble() * 0.24);
      final warm = concertAfterTone(hue: i.isEven ? 38 : 46);
      canvas.drawCircle(
        center,
        radius,
        paint
          ..shader = RadialGradient(
            colors: [
              warm.withValues(alpha: 0.055 * opacity),
              warm.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    paint.shader = null;

    for (var i = 0; i < 3600; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final length = 0.8 + random.nextDouble() * 4.8;
      final angle = -0.15 + random.nextDouble() * 0.7;
      final color = random.nextBool()
          ? const Color(0xFF6F5A3F)
          : const Color(0xFFFFFFFF);
      canvas.drawLine(
        Offset(x, y),
        Offset(x + math.cos(angle) * length, y + math.sin(angle) * length),
        paint
          ..shader = null
          ..color = color.withValues(
            alpha: random.nextDouble() * 0.052 * opacity,
          )
          ..strokeWidth = 0.35 + random.nextDouble() * 0.45,
      );
    }

    for (var i = 0; i < 1600; i++) {
      final dark = random.nextDouble() < .62;
      paint.color = (dark ? const Color(0xFF6B573F) : Colors.white).withValues(
        alpha: random.nextDouble() * (dark ? .035 : .05) * opacity,
      );
      canvas.drawCircle(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
        random.nextDouble() * .65,
        paint,
      );
    }

    canvas.drawRect(
      bounds,
      paint
        ..shader = RadialGradient(
          center: const Alignment(-0.08, -0.12),
          radius: 1.08,
          colors: [
            Colors.white.withValues(alpha: 0.05 * opacity),
            Colors.transparent,
            concertAfterTone(hue: 38).withValues(alpha: 0.12 * opacity),
          ],
          stops: const [0.0, .58, 1.0],
        ).createShader(bounds),
    );
    paint.shader = null;
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PaperTextureOverlayPainter oldDelegate) =>
      opacity != oldDelegate.opacity || seed != oldDelegate.seed;
}

class _PaperPainter extends CustomPainter {
  final PosterMood? mood;
  _PaperPainter(this.mood);
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final paint = Paint();
    canvas.drawRect(
      bounds,
      paint
        ..color =
            (mood?.paperColor ??
            concertAfterTone(hue: kConcertAfterDiaryPageHue)),
    );
    canvas.drawRect(
      bounds,
      paint
        ..shader = LinearGradient(
          colors: [
            (mood?.paperColor ??
                concertAfterTone(hue: kConcertAfterDiaryPageHue)),
            (mood?.paperColor ??
                concertAfterTone(hue: kConcertAfterDiaryPageHue)),
            (mood?.paperColor ??
                concertAfterTone(hue: kConcertAfterDiaryPageHue)),
          ],
          stops: const [0, 0.12, 1],
        ).createShader(bounds),
    );
    paint.shader = null;
    _paperTexture(canvas, size, paint);
    // 장식 종이와 위젯 아래에 인쇄된 노트 줄.
    final inset = size.width * .045;
    final rulePaint = Paint()
      ..color = const Color(
        0xFF77756D,
      ).withValues(alpha: kConcertAfterRuleAlpha)
      ..strokeWidth = kConcertAfterRuleWidth;
    for (
      double y = kConcertAfterRuleSpacing;
      y < size.height - 16;
      y += kConcertAfterRuleSpacing
    ) {
      canvas.drawLine(
        Offset(inset, y),
        Offset(size.width - inset, y),
        rulePaint,
      );
    }
  }

  void _paperTexture(Canvas canvas, Size size, Paint paint) {
    final bounds = Offset.zero & size;
    final random = math.Random(73);

    // Soft uneven washes, like thin paper pieces and aged paper stains.
    for (var i = 0; i < 18; i++) {
      final center = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final radius = size.shortestSide * (0.10 + random.nextDouble() * 0.24);
      final warm = concertAfterTone(hue: i.isEven ? 38 : 46);
      canvas.drawCircle(
        center,
        radius,
        paint
          ..shader = RadialGradient(
            colors: [
              warm.withValues(alpha: 0.055),
              warm.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    paint.shader = null;

    // Fine paper fibres. Different lengths and angles keep it from looking digital.
    for (var i = 0; i < 3600; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final length = 0.8 + random.nextDouble() * 4.8;
      final angle = -0.15 + random.nextDouble() * 0.7;
      final color = random.nextBool()
          ? const Color(0xFF6F5A3F)
          : const Color(0xFFFFFFFF);
      canvas.drawLine(
        Offset(x, y),
        Offset(x + math.cos(angle) * length, y + math.sin(angle) * length),
        paint
          ..shader = null
          ..color = color.withValues(
            alpha:
                random.nextDouble() *
                0.052 *
                ((mood?.textureOpacity ?? .13) / .13),
          )
          ..strokeWidth = 0.35 + random.nextDouble() * 0.45,
      );
    }

    // Tiny pulp specks. These read as analog paper grain rather than photo noise.
    for (var i = 0; i < 1600; i++) {
      final dark = random.nextDouble() < .62;
      paint.color = (dark ? const Color(0xFF6B573F) : Colors.white).withValues(
        alpha: random.nextDouble() * (dark ? .035 : .05),
      );
      canvas.drawCircle(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
        random.nextDouble() * .65,
        paint,
      );
    }

    // Gentle edge aging: reference pages are brighter in the center and warmer on edges.
    canvas.drawRect(
      bounds,
      paint
        ..shader = RadialGradient(
          center: const Alignment(-0.08, -0.12),
          radius: 1.08,
          colors: [
            Colors.white.withValues(alpha: 0.05),
            Colors.transparent,
            concertAfterTone(hue: 38).withValues(alpha: 0.12),
          ],
          stops: const [0.0, .58, 1.0],
        ).createShader(bounds),
    );
    paint.shader = null;
  }

  @override
  bool shouldRepaint(covariant _PaperPainter oldDelegate) =>
      mood != oldDelegate.mood;
}
