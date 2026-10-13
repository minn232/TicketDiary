import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

// [백엔드 수정]
// 폰 맞대기에서 상대를 찾았을 때 - 화면 윗면 가장자리에서 빛이 번지고 물방울처럼 흘러내린 뒤,
// 그 자리에서 상대 카드가 위쪽을 축으로 펼쳐지며 나옴(윗면끼리 맞댄 두 폰에서 동시에 튀어나오는 느낌).
// animation 0→1로 등장, reverse로 다시 윗면으로 들어감.
// exit 0→1은 연결 완료 뒤 카드가 다시 물방울로 오므라들어 화면 아래로 떨어짐(아래에서 공유 카드가 올라옴)
class NearbyPeerReveal extends StatefulWidget {
  final Animation<double> animation;
  final Animation<double>? exit;
  final Color color;
  final Color cardColor;
  // 카드 안 내용 - 카드 바탕이 다 펼쳐진 뒤 나타남
  final Widget child;

  const NearbyPeerReveal({
    super.key,
    required this.animation,
    this.exit,
    required this.color,
    required this.cardColor,
    required this.child,
  });

  @override
  State<NearbyPeerReveal> createState() => _NearbyPeerRevealState();
}

class _NearbyPeerRevealState extends State<NearbyPeerReveal> {
  // 물방울로 오므라들 때 카드 실제 크기가 필요함 (내용에 따라 높이가 달라짐)
  final _cardKey = GlobalKey();

  // 0~0.35 물방울이 내려옴, 0.25~ 카드가 펼쳐짐(살짝 튕김), 0.35~0.75 물방울이 카드 속으로 걷힘
  static const _drop = Interval(0, 0.35, curve: Curves.easeOutCubic);
  static const _unfold = Interval(0.25, 0.85, curve: Curves.easeOutBack);
  static const _cardFade = Interval(0.25, 0.42, curve: Curves.easeOut);
  static const _settle = Interval(0.35, 0.75, curve: Curves.easeInOut);
  static const _contentFade = Interval(0.6, 1, curve: Curves.easeOut);

  // 퇴장: 내용이 먼저 사라지고 0~0.42 물방울 크기로 오므라들며 물들고, 0.42~ 늘어지며 떨어짐
  static const _exitContent = Interval(0, 0.18, curve: Curves.easeOut);
  static const _exitTint = Interval(0.08, 0.38, curve: Curves.easeOut);
  static const _exitShrink = Interval(0, 0.42, curve: Curves.easeInOutCubic);
  static const _exitFall = Interval(0.42, 1, curve: Curves.easeInQuad);
  static const _dropletSize = 54.0;
  static const _cardTop = 16.0;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final exit = widget.exit;
    return AnimatedBuilder(
      animation: Listenable.merge([widget.animation, ?exit]),
      builder: (context, _) {
        final v = widget.animation.value;
        final unfold = _unfold.transform(v);
        final x = exit?.value ?? 0;
        final shrink = _exitShrink.transform(x);
        final fall = _exitFall.transform(x);

        final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
        final cardSize = box != null && box.hasSize ? box.size : null;
        final w = cardSize?.width ?? 1;
        final h = cardSize?.height ?? 1;
        // 오므라들면 원(지름 _dropletSize), 떨어지는 동안은 세로로 늘어진 물방울
        final sx = cardSize == null
            ? 1.0
            : lerpDouble(1, _dropletSize / w, shrink)! * (1 - 0.12 * fall);
        final sy = cardSize == null
            ? 1.0
            : lerpDouble(1, _dropletSize / h, shrink)! * (1 + 0.45 * fall);
        final fallDistance =
            screenHeight - (topInset + _cardTop + h / 2) + _dropletSize;

        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TopDropPainter(
                    drop: _drop.transform(v),
                    settle: _settle.transform(v),
                    color: widget.color,
                  ),
                ),
              ),
            ),
            Positioned(
              top: topInset + _cardTop,
              left: 16,
              right: 16,
              child: Opacity(
                opacity: _cardFade.transform(v),
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.translationValues(
                    0,
                    fallDistance * fall,
                    0,
                  )..multiply(Matrix4.diagonal3Values(sx, sy, 1)),
                  child: Transform(
                    alignment: Alignment.topCenter,
                    transform: Matrix4.diagonal3Values(
                      lerpDouble(0.35, 1, unfold)!,
                      lerpDouble(0.08, 1, unfold)!,
                      1,
                    ),
                    // Material은 모양·색 변화를 스스로 애니메이션해서 매 프레임 한 박자 늦게 따라옴 →
                    // 물방울로 오므라들 때 모서리가 덜 둥글어 보여 바탕은 DecoratedBox로 직접 그림
                    child: DecoratedBox(
                      key: _cardKey,
                      decoration: BoxDecoration(
                        color: Color.lerp(
                          widget.cardColor,
                          widget.color,
                          _exitTint.transform(x),
                        ),
                        borderRadius: BorderRadius.all(
                          Radius.elliptical(
                            lerpDouble(28, w / 2, shrink)!,
                            lerpDouble(28, h / 2, shrink)!,
                          ),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: 0.22 * (1 - shrink),
                            ),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      // 버튼 잉크용 (바탕은 위에서 그림)
                      child: Material(
                        type: MaterialType.transparency,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
                          child: Opacity(
                            opacity:
                                _contentFade.transform(v) *
                                (1 - _exitContent.transform(x)),
                            child: widget.child,
                          ),
                        ),
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
