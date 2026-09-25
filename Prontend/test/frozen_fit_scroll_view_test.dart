import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/frozen_fit_scroll_view.dart';

// 공연 전 페이지 - 화면에 맞게 축소하되, 아코디언(FrozenFitSection)을 펼쳤을 땐 배율을
// 그대로 두고 스크롤되는지.
void main() {
  const pageKey = Key('page');

  Future<void> pumpPage(
    WidgetTester tester, {
    required double baseHeight,
    required bool expanded,
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: FrozenFitScrollView(
                child: Column(
                  key: pageKey,
                  children: [
                    SizedBox(
                      height: baseHeight,
                      child: Center(
                        child: TextButton(
                          onPressed: onTap,
                          child: const Text('펼치기'),
                        ),
                      ),
                    ),
                    if (expanded)
                      const FrozenFitSection(child: SizedBox(height: 400)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double renderedHeight(WidgetTester tester) =>
      tester.getRect(find.byKey(pageKey)).height;

  double maxScroll(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable))
      .position
      .maxScrollExtent;

  testWidgets('접힌 상태는 화면 높이에 맞게 축소된다', (tester) async {
    await pumpPage(tester, baseHeight: 600, expanded: false);

    expect(renderedHeight(tester), closeTo(300, 0.5)); // 600 * 0.5
    expect(maxScroll(tester), 0);
  });

  testWidgets('펼치면 배율은 그대로고 늘어난 만큼 스크롤된다', (tester) async {
    await pumpPage(tester, baseHeight: 600, expanded: false);
    await pumpPage(tester, baseHeight: 600, expanded: true);

    // 전체 1000을 배율 0.5 그대로 -> 500 (다시 맞추면 300이 됐을 것)
    expect(renderedHeight(tester), closeTo(500, 0.5));
    expect(maxScroll(tester), closeTo(200, 0.5));

    // 접으면 원래대로.
    await pumpPage(tester, baseHeight: 600, expanded: false);
    expect(renderedHeight(tester), closeTo(300, 0.5));
    expect(maxScroll(tester), 0);
  });

  testWidgets('펼침 영역이 아닌 내용이 바뀌면 다시 화면에 맞춘다', (tester) async {
    await pumpPage(tester, baseHeight: 600, expanded: false);
    // 데이터를 불러와 지면이 길어진 경우처럼
    await pumpPage(tester, baseHeight: 900, expanded: false);

    expect(renderedHeight(tester), closeTo(300, 0.5));
  });

  testWidgets('축소된 지면 안의 버튼도 눌린다', (tester) async {
    var taps = 0;
    await pumpPage(
      tester,
      baseHeight: 600,
      expanded: false,
      onTap: () => taps++,
    );

    await tester.tap(find.text('펼치기'));
    expect(taps, 1);
  });
}
