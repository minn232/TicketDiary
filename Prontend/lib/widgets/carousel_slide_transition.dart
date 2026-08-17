import 'package:flutter/widgets.dart';

/// 두 페이지를 가로로 "밀어내는" 캐러셀 전환 — [from]이 나가고 [to]가
/// 들어옵니다. 두 페이지가 빈틈없이 맞닿아 함께 이동해서(밀어내기), 경계가
/// 한 줄로 지나가는 것처럼 보입니다(액자 창 안에서 아래 페이지만 넘어가는
/// 느낌).
///
/// - [reverse]=false: [from]은 오른쪽으로 나가고 [to]는 왼쪽에서 들어옵니다.
/// - [reverse]=true: [from]은 왼쪽으로 나가고 [to]는 오른쪽에서 들어옵니다.
///
/// [progress] 0.0이면 [from]만, 1.0이면 [to]만 보입니다. 부모(창)의 폭에
/// 맞춰 슬라이드하고, 창 밖으로 넘친 부분은 잘라냅니다.
class CarouselSlideTransition extends StatelessWidget {
  final Widget from;
  final Widget to;

  /// 0.0(=from만) ~ 1.0(=to만).
  final double progress;

  final bool reverse;

  const CarouselSlideTransition({
    super.key,
    required this.from,
    required this.to,
    required this.progress,
    this.reverse = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final p = progress.clamp(0.0, 1.0);

        final double fromX;
        final double toX;
        if (!reverse) {
          fromX = p * w; // 오른쪽으로 나감
          toX = (p - 1) * w; // 왼쪽에서 들어옴
        } else {
          fromX = -p * w; // 왼쪽으로 나감
          toX = (1 - p) * w; // 오른쪽에서 들어옴
        }

        return ClipRect(
          child: Stack(
            children: [
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(fromX, 0),
                  child: from,
                ),
              ),
              Positioned.fill(
                child: Transform.translate(offset: Offset(toX, 0), child: to),
              ),
            ],
          ),
        );
      },
    );
  }
}
