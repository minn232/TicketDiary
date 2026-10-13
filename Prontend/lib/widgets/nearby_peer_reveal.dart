import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

// [백엔드 수정]
// 폰 맞대기에서 상대를 찾았을 때 - 화면 윗면 가장자리에서 빛이 번지고 물방울처럼 흘러내린 뒤,
// 그 자리에서 상대 카드가 위쪽을 축으로 펼쳐지며 나옴(윗면끼리 맞댄 두 폰에서 동시에 튀어나오는 느낌).
// animation 0→1로 등장, reverse로 다시 윗면으로 들어감
class NearbyPeerReveal extends StatelessWidget {
  final Animation<double> animation;
  final Color color;
  final Color cardColor;
  // 카드 안 내용 - 카드 바탕이 다 펼쳐진 뒤 나타남
  final Widget child;

  const NearbyPeerReveal({
    super.key,
    required this.animation,
    required this.color,
    required this.cardColor,
    required this.child,
  });

  // 0~0.35 물방울이 내려옴, 0.25~ 카드가 펼쳐짐(살짝 튕김), 0.35~0.75 물방울이 카드 속으로 걷힘
  static const _drop = Interval(0, 0.35, curve: Curves.easeOutCubic);
  static const _unfold = Interval(0.25, 0.85, curve: Curves.easeOutBack);
  static const _cardFade = Interval(0.25, 0.42, curve: Curves.easeOut);
  static const _settle = Interval(0.35, 0.75, curve: Curves.easeInOut);
  static const _contentFade = Interval(0.6, 1, curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final v = animation.value;
        final unfold = _unfold.transform(v);
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TopDropPainter(
                    drop: _drop.transform(v),
                    settle: _settle.transform(v),
                    color: color,
                  ),
                ),
              ),
            ),
            Positioned(
              top: topInset + 16,
              left: 16,
              right: 16,
              child: Opacity(
                opacity: _cardFade.transform(v),
                child: Transform(
                  alignment: Alignment.topCenter,
                  transform: Matrix4.diagonal3Values(
                    lerpDouble(0.35, 1, unfold)!,
                    lerpDouble(0.08, 1, unfold)!,
                    1,
                  ),
                  child: Material(
                    color: cardColor,
                    elevation: 6,
                    shadowColor: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(28),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
                      child: Opacity(
                        opacity: _contentFade.transform(v),
                        child: child,
                      ),
                    ),
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

/// 윗면 가장자리의 빛 + 거기서 늘어져 내려오는 물방울.
class _TopDropPainter extends CustomPainter {
  final double drop;
  final double settle;
  final Color color;

  const _TopDropPainter({
    required this.drop,
    required this.settle,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (drop <= 0) return;
    final cx = size.width / 2;
    final fade = 1 - settle;

    // 윗면을 따라 양옆으로 번지는 빛
    final glowWidth = size.width * (0.3 + 0.7 * drop);
    canvas.drawRect(
      Rect.fromLTWH(cx - glowWidth / 2, 0, glowWidth, 10),
      Paint()
        ..shader = LinearGradient(
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: 0.85 * fade),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(cx - glowWidth / 2, 0, glowWidth, 10))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // 윗면에서 늘어져 내려오는 물방울 - 카드가 펼쳐지면 다시 위로 걷힘
    final width = lerpDouble(60, size.width * 0.72, drop)!;
    final depth = 150 * drop * (1 - settle);
    if (depth < 1) return;
    final path = Path()
      ..moveTo(cx - width / 2, 0)
      ..cubicTo(cx - width * 0.28, 0, cx - width * 0.2, depth, cx, depth)
      ..cubicTo(
        cx + width * 0.2,
        depth,
        cx + width * 0.28,
        0,
        cx + width / 2,
        0,
      )
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.95 * fade),
            color.withValues(alpha: 0.45 * fade),
          ],
        ).createShader(Rect.fromLTWH(cx - width / 2, 0, width, depth)),
    );
  }

  @override
  bool shouldRepaint(_TopDropPainter old) =>
      old.drop != drop || old.settle != settle || old.color != color;
}
