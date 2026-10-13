import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

// [백엔드 수정]
// 맞대기 연결 뒤 떨어진 물방울이 바닥에 고여 차오르며 공유 카드가 되는 등장 효과.
// 바닥 가운데에 물방울이 닿아 퍼지고(0~0.15) → 윗면이 가운데가 봉긋한 물결로 차오르고(0.05~0.62)
// → 다 차면 출렁이다 평평해짐(0.62~1). 그동안 물빛이 걷히며 카드 내용이 드러남(0.45~0.85).
// reverse면 그대로 빠져나감
class LiquidRise extends StatelessWidget {
  final Animation<double> animation;
  final Color color;
  final Widget child;

  const LiquidRise({
    super.key,
    required this.animation,
    required this.color,
    required this.child,
  });

  static const _splash = Interval(0, 0.15, curve: Curves.easeOut);
  static const _rise = Interval(0.05, 0.62, curve: Curves.easeInOutCubic);
  static const _settle = Interval(0.62, 1);
  static const _reveal = Interval(0.4, 0.82, curve: Curves.easeInOut);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final v = animation.value;
        if (v >= 1) return child!;
        final reveal = _reveal.transform(v);
        final surface = _LiquidSurface(
          rise: _rise.transform(v),
          settle: _settle.transform(v),
        );
        return Stack(
          fit: StackFit.passthrough,
          children: [
            ClipPath(
              clipper: _LiquidClipper(surface),
              child: Opacity(opacity: reveal, child: child),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _LiquidPainter(
                    surface: surface,
                    splash: _splash.transform(v),
                    color: color,
                    fill: 1 - reveal,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 차오르는 물의 윗면 - 수면 높이 + 가운데 봉긋한 물결.
class _LiquidSurface {
  final double rise;
  final double settle;

  const _LiquidSurface({required this.rise, required this.settle});

  Path path(Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final y = lerpDouble(h + 12, 0, rise)!;
    // 올라오는 동안은 물방울 모양으로 솟아 있다가, 다 차면 위아래로 출렁이며 잦아듦
    final peak = rise < 1
        ? lerpDouble(90, 36, rise)!
        : 36 *
              math.exp(-4.5 * settle) *
              math.cos(2.5 * math.pi * settle) *
              (1 - settle);
    final half = lerpDouble(70, w * 0.45, rise)!;
    return Path()
      ..moveTo(0, h)
      ..lineTo(0, y)
      ..lineTo(cx - half, y)
      ..cubicTo(cx - half * 0.45, y, cx - half * 0.35, y - peak, cx, y - peak)
      ..cubicTo(cx + half * 0.35, y - peak, cx + half * 0.45, y, cx + half, y)
      ..lineTo(w, y)
      ..lineTo(w, h)
      ..close();
  }
}

class _LiquidClipper extends CustomClipper<Path> {
  final _LiquidSurface surface;

  const _LiquidClipper(this.surface);

  @override
  Path getClip(Size size) => surface.path(size);

  @override
  bool shouldReclip(_LiquidClipper old) =>
      old.surface.rise != surface.rise || old.surface.settle != surface.settle;
}

/// 물빛(점점 걷힘) + 바닥에 닿는 물방울의 퍼짐.
class _LiquidPainter extends CustomPainter {
  final _LiquidSurface surface;
  final double splash;
  final Color color;
  final double fill;

  const _LiquidPainter({
    required this.surface,
    required this.splash,
    required this.color,
    required this.fill,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (fill > 0) {
      canvas.drawPath(
        surface.path(size),
        Paint()..color = color.withValues(alpha: 0.82 * fill),
      );
    }
    // 바닥 가운데에 닿은 물방울이 납작하게 퍼지며 수면에 섞임
    if (splash > 0 && splash < 1) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height),
          width: lerpDouble(54, 220, splash)!,
          height: lerpDouble(54, 18, splash)!,
        ),
        Paint()..color = color.withValues(alpha: 0.95 * (1 - splash)),
      );
    }
  }

  @override
  bool shouldRepaint(_LiquidPainter old) =>
      old.surface.rise != surface.rise ||
      old.surface.settle != surface.settle ||
      old.splash != splash ||
      old.fill != fill ||
      old.color != color;
}
