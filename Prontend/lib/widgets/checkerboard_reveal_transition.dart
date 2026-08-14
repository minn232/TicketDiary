import 'package:flutter/material.dart';

/// [from](아래) 위로 [to](위)를 체커보드 격자로 나눠 드러내는 모자이크 전환.
///
/// 화면 전체를 체커보드(바둑판 흑백 칸처럼)로 나눈 뒤, 두 단계로 나눠
/// 진행합니다 — 전체 애니메이션의 앞쪽 절반 동안은 한쪽 색 칸들이, 뒤쪽
/// 절반 동안은 나머지 색 칸들이 "동시에" 칸 왼쪽부터 오른쪽으로 천천히
/// 채워지며 [to]로 바뀝니다. 서로 맞닿은 두 칸은 항상 서로 다른 색(다른
/// 그룹)이라서, 어느 순간에도 이웃한 칸이 동시에 애니메이션 중인 일이
/// 없습니다.
///
/// [to]는 (칸마다 자라나는 크기가 다르더라도) 항상 딱 하나의 [ClipPath]로만
/// 그려지고, [from]은 [to]가 아직 덮지 않은 나머지 영역에만 그려집니다 —
/// 두 레이어가 같은 자리에 겹쳐 그려지지 않으므로(불투명도를 섞어 합성하지
/// 않음) [to]가 반투명한 배경을 가진 위젯이어도 전환 도중 [from]의 내용이
/// 비쳐 보이지 않고, [to] 서브트리 안에 [GlobalKey]로 상태를 유지하는
/// 위젯이 있어도 트리 두 곳에 동시에 마운트되는 일이 없어 안전합니다.
class CheckerboardRevealTransition extends StatelessWidget {
  final Widget from;
  final Widget to;

  /// 0.0(=from만) ~ 1.0(=to가 완전히 덮음).
  final double progress;

  /// true면 두 체커 그룹의 진행 순서를 뒤바꿉니다(역방향 전환에서 살짝
  /// 다른 느낌을 주기 위함 — 어느 색이 먼저/나중에 바뀔지만 바뀌고, 전체
  /// 원리는 동일합니다).
  final bool reverse;

  /// 한 칸의 목표 한 변 길이(px). 실제 칸 수는 크기에 맞춰 계산됩니다.
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
    // 앞쪽 절반(0~0.5)엔 첫 번째 그룹이, 뒤쪽 절반(0.5~1)엔 두 번째
    // 그룹이 진행됩니다. 두 구간이 겹치지 않아서(한쪽이 분수 진행 중일
    // 땐 다른 쪽은 항상 정확히 0 아니면 1), 그 순간 이웃한 두 칸이 동시에
    // "자라나는 중"인 경우가 생기지 않습니다.
    final phase1 = (progress / 0.5).clamp(0.0, 1.0);
    final phase2 = ((progress - 0.5) / 0.5).clamp(0.0, 1.0);
    final firstParity = reverse ? 1 : 0;
    final secondParity = reverse ? 0 : 1;
    final groupProgress = <int, double>{
      firstParity: phase1,
      secondParity: phase2,
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        if (progress < 1)
          ClipPath(
            clipper: _MosaicClipper(
              cellSize: cellSize,
              groupProgress: groupProgress,
              invert: true,
            ),
            child: from,
          ),
        if (progress > 0)
          ClipPath(
            clipper: _MosaicClipper(cellSize: cellSize, groupProgress: groupProgress),
            child: to,
          ),
      ],
    );
  }
}

class _MosaicClipper extends CustomClipper<Path> {
  final double cellSize;

  /// 체커 그룹(`(row+col)%2` 값이 0 또는 1)별 진행도(0~1). 그 그룹에 속한
  /// 모든 칸이 이 진행도만큼 칸 왼쪽부터 오른쪽으로 채워진 영역으로
  /// 드러납니다.
  final Map<int, double> groupProgress;

  /// true면 드러난 영역의 여집합(아직 안 드러난 나머지)을 클립합니다.
  final bool invert;

  const _MosaicClipper({
    required this.cellSize,
    required this.groupProgress,
    this.invert = false,
  });

  @override
  Path getClip(Size size) {
    final revealed = _revealedPath(size);
    if (!invert) return revealed;
    if (size.isEmpty) return Path();
    final full = Path()..addRect(Offset.zero & size);
    return Path.combine(PathOperation.difference, full, revealed);
  }

  Path _revealedPath(Size size) {
    final path = Path();
    if (size.isEmpty) return path;

    final cols = (size.width / cellSize).ceil().clamp(1, 40);
    final rows = (size.height / cellSize).ceil().clamp(1, 64);
    final cw = size.width / cols;
    final ch = size.height / rows;

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final p = groupProgress[(r + c) % 2] ?? 0;
        if (p <= 0) continue;

        final cx = c * cw;
        final cy = r * ch;
        if (p >= 1) {
          // 다 자란 칸: 이음새가 안 보이도록 살짝 겹쳐 그립니다.
          path.addRect(Rect.fromLTWH(cx, cy, cw + 0.5, ch + 0.5));
          continue;
        }
        // 자라나는 중인 칸: 왼쪽 끝에 붙어 진행도만큼 오른쪽으로 넓어지는
        // 사각형(세로는 항상 칸 전체 높이).
        path.addRect(Rect.fromLTWH(cx, cy, cw * p, ch));
      }
    }
    return path;
  }

  @override
  bool shouldReclip(_MosaicClipper oldClipper) {
    return oldClipper.cellSize != cellSize ||
        oldClipper.invert != invert ||
        oldClipper.groupProgress[0] != groupProgress[0] ||
        oldClipper.groupProgress[1] != groupProgress[1];
  }
}
