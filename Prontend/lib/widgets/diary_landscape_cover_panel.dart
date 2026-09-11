import 'package:flutter/material.dart';

/// 가로모드 태블릿에서 [DiaryPageFrame]의 `landscapeCompanionPanel`로 쓰는
/// 정적 장식 패널 — 실제 페이지처럼 보이되 넘어가지 않는, 펼쳐진 책의
/// "이전 페이지" 느낌만 주는 용도.
///
/// [child]로 정적 콘텐츠를 얹을 수 있음(null이면 빈 페이지). 오버레이가
/// 하나만 열려있다고 가정하는 기존 로직을 안 건드리도록, child도
/// GlobalKey 없는 순수 표시용이어야 함.
class DiaryLandscapeCoverPanel extends StatelessWidget {
  final Color pageColor;
  final Widget? child;

  const DiaryLandscapeCoverPanel({
    super.key,
    this.pageColor = const Color(0xFFF4F1E1),
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // child가 포스터 이미지처럼 박스를 꽉 채우는 콘텐츠일 때도 이
      // 패널의 둥근 모서리 밖으로 삐져나오지 않게 잘라냅니다.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: pageColor,
        // 실제 페이지가 오른쪽만 둥근 것과 대칭으로, 이 패널은 왼쪽만
        // 둥글게 해서 스파인(가운데)을 사이에 두고 마주보는 페이지처럼
        // 보이게 합니다.
        borderRadius: const BorderRadius.horizontal(
          left: Radius.circular(15),
        ),
        border: Border.all(color: Colors.black.withValues(alpha: 0.15)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(-4, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}
