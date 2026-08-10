import 'package:flutter/material.dart';

import 'diary_page_frame.dart';
import 'diary_route.dart';
import 'tab_nav_coordinator.dart';

export 'diary_route.dart' show DiaryRoutes, DiaryTab;

const Map<DiaryTab, Color> _diaryTabColors = {
  DiaryTab.diary: Color(0xFFE8AE75),
  DiaryTab.news: Color(0xFF9CB8A7),
  DiaryTab.summary: Color(0xFFD3A39B),
  DiaryTab.settings: Color(0xFFB0B0B0),
};

const Map<DiaryTab, String> _diaryTabTexts = {
  DiaryTab.diary: '다이어리',
  DiaryTab.news: '소식',
  DiaryTab.summary: '결산',
  DiaryTab.settings: '설정',
};

/// 우측 인덱스 탭(다이어리/소식/결산/설정) 공통 빌더
///
/// - [active]는 현재 화면(눌러도 아무 동작 안 하게 처리)
///   - 상세 화면처럼 특정 탭에 속하지 않는 화면은 null로 전달하면 모두 클릭 가능
/// - 탭을 누르면 [TabNavCoordinator]를 거쳐 전환합니다. 직접
///   `Navigator.pushNamedAndRemoveUntil`을 부르지 않는 이유는, 이 탭들이
///   화면 전체와 함께 슬라이드 전환되는 위젯 트리 안에 있어서 전환 도중엔
///   다음 탭이 최종 위치에 없는 순간이 있기 때문입니다 — 코디네이터가
///   "지금 전환 중인지"를 추적해 빠르게 연속으로 눌러도 마지막 요청이
///   안전하게 이어서 실행되도록 합니다([TabNavCoordinator],
///   [TabHitCatcherOverlay] 문서 참고).
List<DiarySideTabSpec> buildDiarySideTabs(
  BuildContext context, {
  required DiaryTab? active,
}) {
  DiarySideTabSpec spec(DiaryTabLayoutSpec layout) {
    final isActive = active != null && layout.tab == active;
    return DiarySideTabSpec(
      right: layout.right,
      top: layout.top,
      isActive: isActive,
      onTap: isActive ? null : () => TabNavCoordinator.instance.requestTab(layout.tab),
      child: DiaryIndexTab(
        color: _diaryTabColors[layout.tab]!,
        text: _diaryTabTexts[layout.tab]!,
      ),
    );
  }

  return [for (final layout in diaryTabLayoutSpecs) spec(layout)];
}
