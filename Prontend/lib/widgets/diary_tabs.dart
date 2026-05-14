import 'package:flutter/material.dart';

import 'diary_page_frame.dart';

/// 앱 전역에서 사용하는 탭 라우트 경로
abstract class DiaryRoutes {
  static const String diary = '/';
  static const String news = '/news';
  static const String summary = '/summary';
  static const String settings = '/settings';

  /// 상세 화면(우선순위 기반 페이지 넘김 방향 결정을 위해 route name 부여)
  static const String concertBefore = '/concert/before';
  static const String concertAfter = '/concert/after';
  static const String favoritePinned = '/settings/favorite_pinned';
}

enum DiaryTab { diary, news, summary, settings }

/// 우측 인덱스 탭(다이어리/소식/결산/설정) 공통 빌더
///
/// - [active]는 현재 화면(눌러도 아무 동작 안 하게 처리)
///   - 상세 화면처럼 특정 탭에 속하지 않는 화면은 null로 전달하면 모두 클릭 가능
/// - 탭을 누르면 스택을 비우고 해당 라우트로 이동(탭 네비게이션 느낌)
List<DiarySideTabSpec> buildDiarySideTabs(
  BuildContext context, {
  required DiaryTab? active,
}) {
  void go(String routeName) {
    Navigator.pushNamedAndRemoveUntil(context, routeName, (route) => false);
  }

  DiarySideTabSpec spec({
    required DiaryTab tab,
    required double right,
    required double top,
    required Color color,
    required String text,
    required String routeName,
  }) {
    return DiarySideTabSpec(
      right: right,
      top: top,
      onTap: (active != null && tab == active) ? null : () => go(routeName),
      child: DiaryIndexTab(color: color, text: text),
    );
  }

  return [
    spec(
      tab: DiaryTab.diary,
      right: 4,
      top: 80,
      color: const Color(0xFFE8AE75),
      text: '다이어리',
      routeName: DiaryRoutes.diary,
    ),
    spec(
      tab: DiaryTab.news,
      right: 7,
      top: 175,
      color: const Color(0xFF9CB8A7),
      text: '소식',
      routeName: DiaryRoutes.news,
    ),
    spec(
      tab: DiaryTab.summary,
      right: 10,
      top: 270,
      color: const Color(0xFFD3A39B),
      text: '결산',
      routeName: DiaryRoutes.summary,
    ),
    spec(
      tab: DiaryTab.settings,
      right: 13,
      top: 450,
      color: const Color(0xFFB0B0B0),
      text: '설정',
      routeName: DiaryRoutes.settings,
    ),
  ];
}

