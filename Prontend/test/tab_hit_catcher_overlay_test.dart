import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/diary_route.dart';
import 'package:ticketdiary/widgets/tab_hit_catcher_overlay.dart';
import 'package:ticketdiary/widgets/tab_nav_coordinator.dart';

/// [TabHitCatcherOverlay]는 [DiaryPageFrame.build]와 완전히 같은 기하
/// 계산을 독립적으로 재현합니다(전환 중엔 실제 프레임이 없어 그 자리를
/// 대신 눌러 받아야 하므로). 두 계산이 어긋나면 전환 중 탭을 눌러도
/// 반응이 없는 버그가 됩니다 - indexTabTopReserve 추가 시 실제로 이
/// 어긋남이 생길 뻔해서, 두 프레임의 렌더링 위치가 일치하는지 확인합니다.
void main() {
  setUp(() {
    TabNavCoordinator.resetForTest();
  });

  Future<Rect> renderDiaryPageFrameRect(
    WidgetTester tester,
    Size viewSize,
    double viewPaddingTop,
    double viewPaddingBottom,
  ) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(
      top: viewPaddingTop,
      bottom: viewPaddingBottom,
    );
    tester.view.viewPadding = FakeViewPadding(
      top: viewPaddingTop,
      bottom: viewPaddingBottom,
    );
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: DiaryPageFrame(
          isTabRoot: true,
          showBinderRings: false,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final box = tester.renderObject<RenderBox>(find.byType(AspectRatio));
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft & box.size;
  }

  Future<Rect> renderHitCatcherRect(
    WidgetTester tester,
    Size viewSize,
    double viewPaddingTop,
    double viewPaddingBottom,
  ) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(
      top: viewPaddingTop,
      bottom: viewPaddingBottom,
    );
    tester.view.viewPadding = FakeViewPadding(
      top: viewPaddingTop,
      bottom: viewPaddingBottom,
    );
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final coordinator = TabNavCoordinator.init(
      navigatorKey: navigatorKey,
      routeBuilder: (from, to) => MaterialPageRoute<void>(
        builder: (context) => const SizedBox.shrink(),
      ),
      initialTab: DiaryTab.diary,
    );

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const SizedBox.expand(),
        builder: (context, child) => Stack(
          children: [
            child!,
            TabHitCatcherOverlay(coordinator: coordinator),
          ],
        ),
      ),
    );
    // isTransitioning=false면 TabHitCatcherOverlay가 SizedBox.shrink()라
    // AspectRatio 자체가 트리에 없음 - 전환 중 상태를 강제로 켭니다.
    coordinator.isTransitioning.value = true;
    await tester.pumpAndSettle();

    final box = tester.renderObject<RenderBox>(find.byType(AspectRatio));
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft & box.size;
  }

  void expectRectsMatch(Rect a, Rect b) {
    const epsilon = 0.5;
    expect((a.left - b.left).abs(), lessThan(epsilon), reason: 'left');
    expect((a.top - b.top).abs(), lessThan(epsilon), reason: 'top');
    expect((a.width - b.width).abs(), lessThan(epsilon), reason: 'width');
    expect((a.height - b.height).abs(), lessThan(epsilon), reason: 'height');
  }

  testWidgets(
    '태블릿형 화면비에서 히트캐처 프레임이 실제 다이어리 프레임과 일치한다',
    (tester) async {
      const viewSize = Size(1024, 1366); // 아이패드 세로 근사치
      final frameRect =
          await renderDiaryPageFrameRect(tester, viewSize, 24, 20);
      final hitRect = await renderHitCatcherRect(tester, viewSize, 24, 20);
      expectRectsMatch(frameRect, hitRect);
    },
  );

  testWidgets(
    '좁고 긴 폰 화면비에서도 히트캐처 프레임이 실제 다이어리 프레임과 일치한다',
    (tester) async {
      const viewSize = Size(393, 852); // iPhone 계열 근사치
      final frameRect =
          await renderDiaryPageFrameRect(tester, viewSize, 59, 34);
      final hitRect = await renderHitCatcherRect(tester, viewSize, 59, 34);
      expectRectsMatch(frameRect, hitRect);
    },
  );
}
