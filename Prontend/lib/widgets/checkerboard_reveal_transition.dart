import 'package:flutter/material.dart';

/// [from](아래) 위로 [to](위)를 격자 셀 단위로 서서히 드러내는 "모자이크/
/// 체커보드" 전환.
///
/// [progress] 0.0이면 [from]만, 1.0이면 [to]가 완전히 덮습니다. 그 사이에서는
/// 화면을 작은 셀 격자로 나눠, 왼쪽 열부터 순서대로(=[reverse]면 오른쪽부터)
/// 셀이 켜지되, 체커보드처럼 이웃한 셀이 반 박자 어긋나며 나타나 자연스러운
/// 모자이크 경계를 만듭니다.
///
/// [to]는 [ClipPath] 하나로 딱 한 번만 그려지고(드러난 셀들의 합집합으로
/// 클립), [from]은 그 아래에 항상 전체가 깔려 있어 성능 부담이 적습니다.
class CheckerboardRevealTransition extends StatelessWidget {
  final Widget from;
  final Widget to;

  /// 0.0(=from만) ~ 1.0(=to가 완전히 덮음).
  final double progress;

  /// false면 왼쪽 열부터, true면 오른쪽 열부터 드러납니다(역방향 전환).
  final bool reverse;

  /// 한 셀의 목표 한 변 길이(px). 실제 셀 수는 크기에 맞춰 계산됩니다.
  final double cellSize;

  const CheckerboardRevealTransition({
    super.key,
    required this.from,
    required this.to,
    required this.progress,
    this.reverse = false,
    this.cellSize = 26,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        from,
        if (progress > 0)
          ClipPath(
            clipper: _CheckerboardClipper(
              progress: progress,
              reverse: reverse,
              cellSize: cellSize,
            ),
            child: to,
          ),
      ],
    );
  }
}

class _CheckerboardClipper extends CustomClipper<Path> {
  final double progress;
  final bool reverse;
  final double cellSize;

  const _CheckerboardClipper({
    required this.progress,
    required this.reverse,
    required this.cellSize,
  });

  @override
  Path getClip(Size size) {
    final path = Path();
    if (progress <= 0 || size.isEmpty) return path;
    if (progress >= 1) {
      path.addRect(Offset.zero & size);
      return path;
    }

    // 셀 수를 크기에 맞춰 계산하되, 너무 많아지지 않게 상한을 둡니다.
    final cols = (size.width / cellSize).ceil().clamp(1, 40);
    final rows = (size.height / cellSize).ceil().clamp(1, 64);
    final cw = size.width / cols;
    final ch = size.height / rows;

    for (int c = 0; c < cols; c++) {
      // 왼쪽부터(정방향) 또는 오른쪽부터(역방향) 켜지도록 열 인덱스를
      // 뒤집습니다.
      final col = reverse ? (cols - 1 - c) : c;
      for (int r = 0; r < rows; r++) {
        // 이웃한 셀이 반 박자 어긋나게(체커보드) 시작 문턱을 정합니다.
        final checker = ((c + r) % 2 == 0) ? 0.0 : 0.5;
        final start = (col + checker) / (cols + 0.5);
        if (progress >= start) {
          // 셀 사이에 1px 미만의 이음새(seam)가 보이지 않도록 살짝 겹쳐
          // 그립니다.
          path.addRect(
            Rect.fromLTWH(c * cw, r * ch, cw + 0.5, ch + 0.5),
          );
        }
      }
    }
    return path;
  }

  @override
  bool shouldReclip(_CheckerboardClipper oldClipper) {
    return oldClipper.progress != progress ||
        oldClipper.reverse != reverse ||
        oldClipper.cellSize != cellSize;
  }
}
