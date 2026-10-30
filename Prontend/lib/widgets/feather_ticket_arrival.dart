import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 화면 위에서 좌우로 흔들리며 원래 티켓 자리에 내려앉는 6초 연출.
/// 부모 Stack 전체를 채우며, [target]은 그 Stack 좌표 기준입니다.
class FeatherTicketArrival extends StatefulWidget {
  const FeatherTicketArrival({
    super.key,
    required this.target,
    required this.child,
    required this.onComplete,
  });

  static const duration = Duration(seconds: 6);
  static const impactDuration = Duration(milliseconds: 700);
  final Rect target;
  final Widget child;
  final VoidCallback onComplete;

  @override
  State<FeatherTicketArrival> createState() => _FeatherTicketArrivalState();
}

class _FeatherTicketArrivalState extends State<FeatherTicketArrival>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
            vsync: this,
            duration:
                FeatherTicketArrival.duration +
                FeatherTicketArrival.impactDuration,
          )
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) widget.onComplete();
          })
          ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          final elapsed =
              _controller.value *
              (FeatherTicketArrival.duration +
                      FeatherTicketArrival.impactDuration)
                  .inMicroseconds;
          final t = (elapsed / FeatherTicketArrival.duration.inMicroseconds)
              .clamp(0.0, 1.0);
          final impact =
              ((elapsed - FeatherTicketArrival.duration.inMicroseconds) /
                      FeatherTicketArrival.impactDuration.inMicroseconds)
                  .clamp(0.0, 1.0);
          final target = widget.target;
          final settling = math.pow(1 - t, .8).toDouble();
          // 끝에 접근할 때 감속하고 방향 전환 뒤 바로 가속합니다.
          // 끝에서 오래 머물게 하던 추가 사인 보정은 적용하지 않습니다.
          final sway = math.sin(t * math.pi * 3);
          final amplitude = 10 * math.min(44.0, target.width * .16);
          final scale = 2 - Curves.easeInOut.transform(t);
          // 낙하와 착지 충격까지 암전을 유지하고, 먼지가 사라질 때 해제합니다.
          final darkness =
              .65 *
              (1 -
                  Curves.easeInOut.transform(
                    ((impact - .35) / .65).clamp(0.0, 1.0),
                  ));
          final y =
              -target.height * 2.5 +
              (target.top + target.height * 2.5) *
                  Curves.easeOutSine.transform(t);
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: ColoredBox(
                  key: const ValueKey('arrival-dimming'),
                  color: Colors.black.withValues(alpha: darkness),
                ),
              ),
              Positioned(
                left: target.left + sway * amplitude * settling,
                top: y,
                width: target.width,
                height: target.height,
                child: Transform.rotate(
                  angle: -math.sin(t * math.pi * 3 + .6) * .16 * settling,
                  child: Transform.scale(
                    key: const ValueKey('arrival-scale'),
                    scale: scale,
                    child: child,
                  ),
                ),
              ),
              if (t >= 1 && impact < 1)
                Positioned.fill(
                  child: CustomPaint(
                    key: const ValueKey('arrival-impact'),
                    painter: _LandingDustPainter(target, impact),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 티켓 둘레에서 바깥으로 번지는 부드러운 흰 먼지.
/// 매 프레임 같은 입자를 이동시켜 떨림 없이 자연스럽게 흩어집니다.
class _LandingDustPainter extends CustomPainter {
  const _LandingDustPainter(this.target, this.progress);

  final Rect target;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final spread = Curves.easeOutCubic.transform(progress);
    final fade = math.pow(1 - progress, 2).toDouble();
    final distance = math.min(48.0, target.width * .2);
    // 종이 표면을 가리지 않고 가장자리 바깥에만 공기를 표시합니다.
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()
          ..addRRect(RRect.fromRectAndRadius(target, const Radius.circular(8))),
      ),
    );
    for (var i = 0; i < 28; i++) {
      final angle = i * math.pi * 2 / 28;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final edgeDistance = math.min(
        target.width / 2 / math.max(direction.dx.abs(), .001),
        target.height / 2 / math.max(direction.dy.abs(), .001),
      );
      final variation = .65 + (i % 5) * .09;
      final center =
          target.center +
          direction * (edgeDistance + 3 + distance * spread * variation);
      final radius = (5 + (i % 4) * 2.0) * (1 + spread * .8);
      final bounds = Rect.fromCircle(center: center, radius: radius);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: .8 * fade),
              Colors.white.withValues(alpha: .3 * fade),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0, .45, 1],
          ).createShader(bounds),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LandingDustPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.target != target;
}
