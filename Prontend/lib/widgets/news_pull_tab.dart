import 'dart:math' show pi;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'diary_page_frame.dart';
import 'pressable_scale.dart';
import 'responsive_text.dart';

/// 소식 페이지 상단 경계에 "페이지 뒤에서" 끼워 올린 작은 페이지 조각(풀탭).
///
/// [DiaryPageFrame.frameBehindPage]로 넘겨 메인 페이지보다 뒤에 그립니다 —
/// 우측 인덱스 탭이 페이지 오른쪽 경계 밖으로만 삐져나와 보이듯, 이 조각도
/// 페이지에 가려지고 페이지 상단 경계선 위로 삐져나온 부분만 보입니다.
/// 아래쪽 끝은 페이지 뒤로 들어가(경계선에 맞닿아) 손잡이처럼 보입니다.
///
/// [slide] 0.0이면 왼쪽 끝(원래 자리), 1.0이면 오른쪽 끝입니다. 조각을 누르면
/// [onTap]이 호출되며(슬라이드/전환은 부모가 담당), 화살표는 진행 방향을
/// 가리키도록 자동으로 바뀝니다(왼쪽에선 오른쪽 화살표, 오른쪽에선 왼쪽).
class NewsPullTabOverlay extends StatelessWidget {
  final Animation<double> slide;
  final VoidCallback onTap;

  /// 이 오버레이가 얹히는 소식 프레임의 페이지 상단 여백(px). 조각의 아래
  /// 끝을 이 경계선에 맞닿게 배치하는 기준입니다.
  final double pageTop;

  /// 하트 로딩 표시 진행도(0~1, 매 바퀴 반복). 0(또는 1)이면 하트가 온전히
  /// 보이고, 그 사이에는 하트 정중앙을 중심으로 시계방향 쐐기 모양으로
  /// 앞쪽 절반엔 사라지고 뒤쪽 절반엔 다시 나타납니다 — 최신 소식을 불러오는
  /// 동안(로딩 중)에만 부모가 이 값을 실제로 진행시킵니다.
  final Animation<double> heartWipe;

  const NewsPullTabOverlay({
    super.key,
    required this.slide,
    required this.onTap,
    required this.pageTop,
    required this.heartWipe,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = DiaryPageFrame.computeRingMetrics(
          frameWidth: constraints.maxWidth,
          frameHeight: constraints.maxHeight,
          pageTop: pageTop,
        );

        // 하트(30) + 화살표(18) + 좌우 패딩(9*2) + 테두리(1*2)를 여유 있게
        // 담을 수 있도록 72로 잡았습니다(66이면 테두리 두께만큼 딱 맞아
        // RenderFlex가 살짝 넘칩니다).
        final tabWidth = context.rs(72);
        final tabHeight = context.rs(58);
        final inset = context.rs(8);
        // 조각의 아래쪽 일부는 페이지 상단 경계선 아래(페이지 뒤)로 들어가
        // 가려집니다 — 그만큼 "페이지 뒤에서 끼워 올린" 느낌이 납니다.
        final overlapIntoPage = context.rs(18);
        // 조각의 아래 끝이 (경계선 + overlap)에 오도록 top을 잡습니다.
        final topY = pageTop + overlapIntoPage - tabHeight;

        final leftX = metrics.pivotX + inset;
        final rightX = metrics.pivotX + metrics.pageWidth - tabWidth - inset;

        // 조각 안에서 보이는(경계선 위) 부분의 비율 — 아이콘을 그 안쪽에
        // 두기 위한 정렬 기준으로 씁니다.
        final visibleFraction =
            ((pageTop - topY) / tabHeight).clamp(0.0, 1.0);

        return AnimatedBuilder(
          animation: slide,
          builder: (context, _) {
            final t = slide.value.clamp(0.0, 1.0);
            final x = lerpDouble(leftX, rightX, t)!;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: x,
                  top: topY,
                  width: tabWidth,
                  height: tabHeight,
                  child: PressableScale(
                    onTap: onTap,
                    pressScale: 0.94,
                    tapScale: 1.05,
                    child: _PullTabPiece(
                      pointLeft: t > 0.5,
                      visibleFraction: visibleFraction,
                      heartWipe: heartWipe,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _PullTabPiece extends StatelessWidget {
  /// true면 왼쪽 화살표(오른쪽에 있을 때 → 왼쪽으로 돌아감), false면 오른쪽.
  final bool pointLeft;

  /// 조각에서 페이지 경계선 위로 보이는 부분의 세로 비율(0~1). 아이콘을
  /// 그 보이는 영역 안에 두기 위해 씁니다.
  final double visibleFraction;

  /// 하트 로딩 표시 진행도. [NewsPullTabOverlay.heartWipe] 참고.
  final Animation<double> heartWipe;

  const _PullTabPiece({
    required this.pointLeft,
    required this.visibleFraction,
    required this.heartWipe,
  });

  static const Color _pieceColor = Color(0xFFF7F4E6);
  static const Color _heartColor = Color(0xFFE0455E);

  @override
  Widget build(BuildContext context) {
    // 아이콘을 "보이는(경계선 위) 영역"의 세로 중앙에 오도록 정렬값을
    // 계산합니다 — 보이는 영역이 조각 위쪽 일부라, Alignment.y를 그만큼
    // 위로 올립니다.
    final iconAlignY = (visibleFraction - 1.0).clamp(-1.0, 0.0);

    return Container(
      decoration: BoxDecoration(
        color: _pieceColor,
        // 위쪽(삐져나온 쪽) 모서리만 둥글게 — 아래쪽은 페이지 뒤로 각지게
        // 들어갑니다.
        borderRadius: BorderRadius.vertical(top: Radius.circular(context.rs(11))),
        border: Border.all(
          color: Colors.black.withValues(alpha: 0.14),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: EdgeInsets.symmetric(horizontal: context.rs(9)),
      child: Align(
        alignment: Alignment(0, iconAlignY),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            AnimatedBuilder(
              animation: heartWipe,
              builder: (context, child) => ClipPath(
                clipper: _HeartWipeClipper(heartWipe.value),
                child: child,
              ),
              child: Icon(Icons.search, size: context.rs(30), color: _heartColor),
            ),
            Icon(
              pointLeft ? Icons.chevron_left : Icons.chevron_right,
              size: context.rs(18),
              color: Colors.brown.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}

/// [NewsPullTabOverlay.heartWipe] 진행도(0~1)를 하트 아이콘의 시계방향
/// 쐐기(파이) 클립으로 바꿉니다.
///
/// - 0.0~0.5(앞쪽 절반): 정중앙에서 12시 방향부터 시계방향으로 자라나는
///   쐐기 "만큼" 하트에서 빼서(사라지게 해서) 보여줍니다 — 0.5에 도달하면
///   쐐기가 원 전체를 덮어 하트가 완전히 사라집니다.
/// - 0.5~1.0(뒤쪽 절반): 같은 자리에서 이어서 시계방향으로 자라나는 쐐기
///   "만" 보여줍니다 — 1.0에 도달하면 쐐기가 원 전체가 되어 하트가 다시
///   완전히 보입니다.
///
/// 0.0과 1.0 양 끝 모두 하트가 온전히 보이는 상태로 이어져서, 이 값을
/// 반복시키면(0→1→0→...) 시계 방향으로 계속 회전하는 하나의 직선 단면을
/// 따라 하트가 사라졌다 나타나기를 반복하는 것처럼 보입니다.
class _HeartWipeClipper extends CustomClipper<Path> {
  final double progress;

  const _HeartWipeClipper(this.progress);

  @override
  Path getClip(Size size) {
    if (progress < 0.5) {
      final wedge = _wedgePath(size, progress / 0.5);
      final full = Path()..addRect(Offset.zero & size);
      return Path.combine(PathOperation.difference, full, wedge);
    }
    return _wedgePath(size, (progress - 0.5) / 0.5);
  }

  /// 아이콘 정중앙을 중심으로, 12시 방향에서 시계방향으로 [fraction](0~1)
  /// 바퀴만큼 자라나는 쐐기(파이 조각) 모양. 반지름을 대각선 길이로 넉넉히
  /// 잡아 아이콘 모양과 무관하게 항상 원하는 만큼 완전히 덮거나 비웁니다.
  Path _wedgePath(Size size, double fraction) {
    final path = Path();
    if (fraction <= 0 || size.isEmpty) return path;
    final center = Offset(size.width / 2, size.height / 2);
    if (fraction >= 1) {
      path.addOval(Rect.fromCircle(center: center, radius: size.longestSide));
      return path;
    }
    final radius = size.longestSide;
    path.moveTo(center.dx, center.dy);
    path.arcTo(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2, // 12시 방향에서 시작.
      fraction * 2 * pi, // 시계방향(양수)으로 자라남.
      false,
    );
    path.close();
    return path;
  }

  @override
  bool shouldReclip(_HeartWipeClipper oldClipper) =>
      oldClipper.progress != progress;
}
