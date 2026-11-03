import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'paper_texture_cache.dart';

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
    // [백엔드 수정] 고정 투명도로 구워 두고 칠할 때 곱함 - 공연마다 투명도가 달라도 캐시를 같이 씀.
    final bake = math.max(opacity, _kHanjiTileMaxOpacity);
    PaperTextureCache.paint(
      canvas,
      size,
      (
        'hanji',
        seed,
        bake,
        kHanjiTextureFiberDensity,
        kHanjiTextureFiberAlpha,
        kHanjiTextureSpeckDensity,
        kHanjiTextureSpeckAlpha,
      ),
      (c, s) => _paintTexture(c, s, bake),
      opacity: opacity / bake,
    );
  }

  void _paintTexture(Canvas canvas, Size size, double opacity) {
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

// [백엔드 수정] 공연 후 배경 상자용 반복 타일 크기와, 기존 큰 상자 밀도를 맞추는 기준 넓이.
const double kHanjiTileSize = 256;
const double _kHanjiTileReferenceArea = 230000;
const double _kHanjiTileMaxOpacity = .22;

/// [백엔드 수정] 크기와 무관한 한지 질감 - 타일 한 장을 반복해 그리고 투명도는 칠할 때 곱함.
void paintHanjiTiled(
  Canvas canvas,
  Size size, {
  required int seed,
  double opacity = kHanjiTextureOpacity,
}) {
  PaperTextureCache.paintTiled(
    canvas,
    size,
    ('hanji-tile', kHanjiTextureSeed),
    tileSize: kHanjiTileSize,
    draw: _paintHanjiTile,
    phase: Offset(
      (seed % kHanjiTileSize.toInt()).toDouble(),
      ((seed >> 8) % kHanjiTileSize.toInt()).toDouble(),
    ),
    opacity: opacity / _kHanjiTileMaxOpacity,
  );
}

/// 이음매 없는 타일 - 가장자리에 걸친 섬유·얼룩은 반대편에도 그림.
void _paintHanjiTile(Canvas canvas, Size size) {
  final w = size.width;
  final h = size.height;
  final tile = Offset.zero & size;
  void wrapped(Rect bounds, void Function(Offset shift) draw) {
    for (final dx in [-w, 0.0, w]) {
      for (final dy in [-h, 0.0, h]) {
        final shift = Offset(dx, dy);
        if (bounds.shift(shift).overlaps(tile)) draw(shift);
      }
    }
  }

  // 기존 상자는 개수 상한(얼룩 45·섬유 650·입자 6500)에 걸려 있어 그 밀도를 타일 넓이로 환산.
  int count(int clamped) =>
      math.max(1, (clamped * w * h / _kHanjiTileReferenceArea).round());
  const ratio = _kHanjiTileMaxOpacity / kHanjiTextureOpacity;

  canvas.save();
  canvas.clipRect(tile);
  final rnd = math.Random(kHanjiTextureSeed);
  for (var i = 0, n = count(45); i < n; i++) {
    final center = Offset(rnd.nextDouble() * w, rnd.nextDouble() * h);
    final radius = 12 + rnd.nextDouble() * 48;
    final tint = (i.isEven ? const Color(0xFFFFF6E5) : const Color(0xFF554435))
        .withValues(
          alpha: ((.018 + rnd.nextDouble() * .025) * ratio).clamp(0.0, 1.0),
        );
    wrapped(Rect.fromCircle(center: center, radius: radius), (shift) {
      final c = center + shift;
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [tint, tint.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: c, radius: radius)),
      );
    });
  }

  final paint = Paint();
  for (var i = 0, n = count(650); i < n; i++) {
    final start = Offset(rnd.nextDouble() * w, rnd.nextDouble() * h);
    final length = 1 + rnd.nextDouble() * 7;
    final angle = rnd.nextDouble() * math.pi;
    final end =
        start + Offset(math.cos(angle) * length, math.sin(angle) * length);
    paint
      ..color = (rnd.nextBool() ? Colors.white : const Color(0xFF7B654A))
          .withValues(
            alpha: (rnd.nextDouble() * kHanjiTextureFiberAlpha * ratio).clamp(
              0.0,
              1.0,
            ),
          )
      ..strokeWidth = .35 + rnd.nextDouble() * .45
      ..strokeCap = StrokeCap.round;
    wrapped(
      Rect.fromPoints(start, end).inflate(1),
      (shift) => canvas.drawLine(start + shift, end + shift, paint),
    );
  }

  for (var i = 0, n = count(6500); i < n; i++) {
    paint
      ..color = (rnd.nextBool() ? Colors.white : Colors.black).withValues(
        alpha: (rnd.nextDouble() * kHanjiTextureSpeckAlpha * ratio).clamp(
          0.0,
          1.0,
        ),
      )
      ..strokeCap = StrokeCap.butt;
    canvas.drawRect(
      Rect.fromLTWH(rnd.nextDouble() * w, rnd.nextDouble() * h, 1, 1),
      paint,
    );
  }
  canvas.restore();
}
