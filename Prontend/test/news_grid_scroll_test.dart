import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// [news_screen.dart]의 `_buildNewsGrid`와 동일한 그리드 델리게이트/physics
/// 구성(2열, 행 높이 = (전체높이-60)/2, BouncingScrollPhysics)을 재현해,
/// 카드가 4개를 넘어도(과거엔 NeverScrollableScrollPhysics라 5번째부터는
/// 화면 밖으로 잘려 아예 안 보였습니다) 스크롤로 나머지 카드를 볼 수
/// 있는지 검증합니다.
Widget buildNewsLikeGrid(double maxHeight, int itemCount) {
  const spacing = 18.0;
  final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 2,
    crossAxisSpacing: spacing,
    mainAxisSpacing: spacing,
    mainAxisExtent: (maxHeight - 60) / 2,
  );

  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: maxHeight,
        child: GridView.builder(
          padding: EdgeInsets.zero,
          physics: const BouncingScrollPhysics(),
          gridDelegate: gridDelegate,
          itemCount: itemCount,
          itemBuilder: (context, index) =>
              SizedBox.expand(child: Text('card_$index')),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('4개 이하면 스크롤이 불필요하다(기존 2x2 모양 그대로 유지)', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildNewsLikeGrid(700, 4));
    await tester.pumpAndSettle();

    final position = Scrollable.of(
      tester.element(find.text('card_0')),
    ).position;
    expect(position.maxScrollExtent, 0);
  });

  testWidgets('5개 이상이면 스크롤로 나머지 카드를 볼 수 있다(과거엔 잘려서 안 보였음)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildNewsLikeGrid(700, 6));
    await tester.pumpAndSettle();

    final position = Scrollable.of(
      tester.element(find.text('card_0')),
    ).position;
    expect(position.maxScrollExtent, greaterThan(0));

    await tester.drag(find.byType(GridView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });
}
