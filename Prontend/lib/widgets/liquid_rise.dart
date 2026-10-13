import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

// [백엔드 수정]
// 맞대기 연결 뒤 물방울이 패널에 고여 패널 전체를 덮을 만큼 차올랐다 걷히는 효과(갈색→크림색).
// 다 덮인 순간(coveredAt)에 아래 내용을 바꿈
class LiquidFlood extends StatelessWidget {
  final Animation<double> animation;
  // 떨어지는 물방울·수면 띠 색
  final Color color;
  // 다 차올랐을 때의 물 색 - 패널 바탕과 같게
  final Color fillColor;

  const LiquidFlood({
    super.key,
    required this.animation,
    required this.color,
    required this.fillColor,
  });

  // 이 시점이면 패널이 다 덮여 아래 내용을 바꿔도 안 보임
  static const double coveredAt = 0.56;

  static const _splash = Interval(0, 0.12, curve: Curves.easeOut);
  static const _rise = Interval(0.04, 0.55, curve: Curves.easeInOutCubic);
  static const _lighten = Interval(0.12, 0.55, curve: Curves.easeInOut);
  static const _clear = Interval(0.62, 0.95, curve: Curves.easeInOut);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final v = animation.value;
          return CustomPaint(
            size: Size.infinite,
            painter: _FloodPainter(
              rise: _rise.transform(v),
              splash: _splash.transform(v),
              lighten: _lighten.transform(v),
              opacity: 1 - _clear.transform(v),
              color: color,
              fillColor: fillColor,
            ),
          );
        },
      ),
    );
  }
}

class _FloodPainter extends CustomPainter {
  final double rise;
  final double splash;
  final double lighten;
  final double opacity;
  final Color color;
  final Color fillColor;

  const _FloodPainter({
    required this.rise,
    required this.splash,
    required this.lighten,
    required this.opacity,
    required this.color,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    // 맨 위 너머(-48)까지 차올라 봉긋한 물결까지 패널을 완전히 덮음
    final y = lerpDouble(h + 12, -48, rise)!;
    final peak = lerpDouble(90, 30, rise)!;
    final half = lerpDouble(70, w * 0.45, rise)!;
    final surface = Path()
      ..moveTo(0, y)
      ..lineTo(cx - half, y)
      ..cubicTo(cx - half * 0.45, y, cx - half * 0.35, y - peak, cx, y - peak)
      ..cubicTo(cx + half * 0.35, y - peak, cx + half * 0.45, y, cx + half, y)
      ..lineTo(w, y);
    final body = Path.from(surface)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();

    canvas.drawPath(
      body,
      Paint()
        ..color = Color.lerp(
          color,
          fillColor,
          lighten,
        )!.withValues(alpha: 0.97 * opacity),
    );
    // 수면 띠 - 옅어진 물에서도 물 느낌이 남게
    canvas.drawPath(
      surface,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = color.withValues(alpha: (1 - 0.5 * lighten) * opacity),
    );
    // 바닥 가운데에 닿은 물방울이 납작하게 퍼짐
    if (splash > 0 && splash < 1) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx, h),
          width: lerpDouble(54, 220, splash)!,
          height: lerpDouble(54, 18, splash)!,
        ),
        Paint()..color = color.withValues(alpha: 0.95 * (1 - splash)),
      );
    }
  }

  @override
  bool shouldRepaint(_FloodPainter old) =>
      old.rise != rise ||
      old.splash != splash ||
      old.lighten != lighten ||
      old.opacity != opacity ||
      old.color != color ||
      old.fillColor != fillColor;
}
