import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/diary_tab_flip_route.dart';

/// [DiaryPageFrame]은 Center+AspectRatio로 프레임을 가로/세로 모두 중앙
/// 정렬합니다. [DiaryTabFlipTransition]은 실제 프레임을 다시 그리지 않고
/// (전환 중엔 넘어가는 속지만 보여줌) 같은 위치/크기를 독립적으로 계산해서
/// 겹쳐 그리는데, 이 두 계산이 어긋나면 전환 애니메이션이 실제 다이어리
/// 페이지 위치와 안 맞아 보입니다(세로 마진을 빠뜨렸던 버그가 실제로 있었음).
/// 여러 화면비(폰/태블릿 근사치)에서 두 계산 결과가 실제 렌더링 기준으로
/// 일치하는지 확인합니다.
void main() {
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

  Future<Rect> renderFlipLeavesRect(
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
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: DiaryTabFlipTransition(
          animation: const AlwaysStoppedAnimation<double>(0.5),
          forward: true,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final box = tester.renderObject<RenderBox>(
      find.byKey(DiaryTabFlipTransition.leavesBoxKey),
    );
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

  testWidgets('좁고 긴 폰 화면비에서 전환 애니메이션 프레임이 실제 다이어리 프레임과 일치한다', (
    tester,
  ) async {
    const viewSize = Size(393, 852); // iPhone 계열 근사치
    final frameRect =
        await renderDiaryPageFrameRect(tester, viewSize, 59, 34);
    final leavesRect = await renderFlipLeavesRect(tester, viewSize, 59, 34);
    expectRectsMatch(frameRect, leavesRect);
  });

  testWidgets('넓은(태블릿형) 화면비에서도 전환 애니메이션 프레임이 실제 다이어리 프레임과 일치한다', (
    tester,
  ) async {
    const viewSize = Size(1024, 1366); // 아이패드 세로 근사치
    final frameRect =
        await renderDiaryPageFrameRect(tester, viewSize, 24, 20);
    final leavesRect = await renderFlipLeavesRect(tester, viewSize, 24, 20);
    expectRectsMatch(frameRect, leavesRect);
  });

  testWidgets('정사각형에 가까운 화면비에서도 일치한다', (tester) async {
    const viewSize = Size(800, 900);
    final frameRect = await renderDiaryPageFrameRect(tester, viewSize, 40, 20);
    final leavesRect = await renderFlipLeavesRect(tester, viewSize, 40, 20);
    expectRectsMatch(frameRect, leavesRect);
  });
}
