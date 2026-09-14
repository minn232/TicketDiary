import 'dart:math' as math;

import 'package:flutter/material.dart';

const int kHanjiTextureSeed = 91;
const double kHanjiTextureOpacity = .13;

const double kHanjiTextureFiberDensity = 110;
const double kHanjiTextureFiberAlpha = .12;
const double kHanjiTextureSpeckDensity = 12;
const double kHanjiTextureSpeckAlpha = .095;

class HanjiTexture extends StatelessWidget {
  final double opacity;
  final Widget? child;

  const HanjiTexture({
    super.key,
    this.opacity = kHanjiTextureOpacity,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: HanjiTexturePainter(opacity: opacity),
      child: child,
    );
  }
}

/// 모든 종이 위젯과 배경 상자에서 공유하는 펄프·섬유·입자 질감.
class HanjiTexturePainter extends CustomPainter {
  final double opacity;
  final int seed;

  const HanjiTexturePainter({
    this.opacity = kHanjiTextureOpacity,
    this.seed = kHanjiTextureSeed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || opacity <= 0) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final rnd = math.Random(seed);
    // 넓고 희미한 얼룩으로 종이 펄프의 불균일한 색을 표현한다.
    for (var i = 0; i < 45; i++) {
      final center = Offset(
        rnd.nextDouble() * size.width,
        rnd.nextDouble() * size.height,
      );
      final radius = 12 + rnd.nextDouble() * 48;
      final tint =
          (i.isEven ? const Color(0xFFFFF6E5) : const Color(0xFF554435))
              .withValues(
                alpha:
                    ((.018 + rnd.nextDouble() * .025) *
                            opacity /
                            kHanjiTextureOpacity)
                        .clamp(0.0, 1.0),
              );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [tint, tint.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    final paint = Paint();

    final fiberCount = (size.width * size.height / kHanjiTextureFiberDensity)
        .round()
        .clamp(24, 650);
    for (var i = 0; i < fiberCount; i++) {
      final start = Offset(
        rnd.nextDouble() * size.width,
        rnd.nextDouble() * size.height,
      );
      final length = 1 + rnd.nextDouble() * 7;
      final angle = rnd.nextDouble() * math.pi;
      paint
        ..color = (rnd.nextBool() ? Colors.white : const Color(0xFF7B654A))
            .withValues(
              alpha:
                  (rnd.nextDouble() *
                          kHanjiTextureFiberAlpha *
                          opacity /
                          kHanjiTextureOpacity)
                      .clamp(0.0, 1.0),
            )
        ..strokeWidth = .35 + rnd.nextDouble() * .45
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        start,
        start + Offset(math.cos(angle) * length, math.sin(angle) * length),
        paint,
      );
    }

    final speckCount = (size.width * size.height / kHanjiTextureSpeckDensity)
        .round()
        .clamp(12, 6500);
    for (var i = 0; i < speckCount; i++) {
      paint
        ..color = (rnd.nextBool() ? Colors.white : Colors.black).withValues(
          alpha:
              (rnd.nextDouble() *
                      kHanjiTextureSpeckAlpha *
                      opacity /
                      kHanjiTextureOpacity)
                  .clamp(0.0, 1.0),
        )
        ..strokeCap = StrokeCap.butt;
      canvas.drawRect(
        Rect.fromLTWH(
          rnd.nextDouble() * size.width,
          rnd.nextDouble() * size.height,
          1,
          1,
        ),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant HanjiTexturePainter oldDelegate) =>
      opacity != oldDelegate.opacity || seed != oldDelegate.seed;
}
