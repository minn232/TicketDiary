import 'dart:math' as math;

import 'package:flutter/material.dart';

/// [child] 주위에 은은하게 반짝이는(골든 글로우 + 트윙클) 효과를 겹쳐 보여줍니다.
///
/// 순수하게 시각적인 장식용 오버레이라 터치 이벤트는 그대로 [child]에게
/// 전달됩니다("여기 눌러볼 수 있어요"를 알려주는 용도로 씁니다).
class SparkleHighlight extends StatefulWidget {
  final Widget child;
  final BorderRadius borderRadius;

  const SparkleHighlight({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
  });

  @override
  State<SparkleHighlight> createState() => _SparkleHighlightState();
}

class _SparkleHighlightState extends State<SparkleHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const _glowColor = Color(0xFFFFD54F);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
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
      builder: (context, child) {
        final phase = _controller.value * 2 * math.pi;
        final glow = (math.sin(phase) + 1) / 2;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // 커졌다 작아졌다 하는 은은한 골든 글로우.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: widget.borderRadius,
                    boxShadow: [
                      BoxShadow(
                        color: _glowColor.withValues(
                          alpha: 0.25 + glow * 0.35,
                        ),
                        blurRadius: 8 + glow * 14,
                        spreadRadius: glow * 3,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            child!,
            for (final corner in _TwinkleCorner.values)
              _buildTwinkle(corner, phase),
          ],
        );
      },
      child: widget.child,
    );
  }

  Widget _buildTwinkle(_TwinkleCorner corner, double basePhase) {
    // 코너마다 위상을 어긋나게 해서 반짝임이 순차적으로 보이게 합니다.
    final twinklePhase = basePhase + corner.index * (math.pi / 2);
    final twinkle = ((math.sin(twinklePhase) + 1) / 2).clamp(0.0, 1.0);

    return Positioned(
      top: corner.isTop ? -6 : null,
      bottom: corner.isTop ? null : -6,
      left: corner.isLeft ? -6 : null,
      right: corner.isLeft ? null : -6,
      child: IgnorePointer(
        child: Opacity(
          opacity: twinkle,
          child: Icon(
            Icons.auto_awesome,
            size: 10 + twinkle * 5,
            color: _glowColor,
          ),
        ),
      ),
    );
  }
}

enum _TwinkleCorner {
  topLeft(isTop: true, isLeft: true),
  topRight(isTop: true, isLeft: false),
  bottomRight(isTop: false, isLeft: false),
  bottomLeft(isTop: false, isLeft: true);

  final bool isTop;
  final bool isLeft;

  const _TwinkleCorner({required this.isTop, required this.isLeft});
}
