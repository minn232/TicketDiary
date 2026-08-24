import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// [news_screen.dart]의 `_buildNewsGrid`와 동일한 그리드 델리게이트/physics
/// 구성(가로 스크롤, 2행, 카드 폭 = (전체너비-spacing)/2, BouncingScrollPhysics)을
/// 재현해, 카드가 4개를 넘어도 오른쪽으로 스크롤해 나머지 카드를 볼 수
/// 있는지 검증합니다.
Widget buildNewsLikeGrid(double maxWidth, int itemCount) {
  const spacing = 18.0;
  const height = 500.0;
  final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 2, // 가로 스크롤이라 세로 칸(행) 수를 뜻함
    crossAxisSpacing: spacing,
    mainAxisSpacing: spacing,
    mainAxisExtent: (maxWidth - spacing) / 2, // 카드 가로폭(=창 폭 절반, 4개/화면)
  );

  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: maxWidth,
          height: height,
          child: GridView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            physics: const BouncingScrollPhysics(),
            gridDelegate: gridDelegate,
            itemCount: itemCount,
            itemBuilder: (context, index) =>
                SizedBox.expand(child: Text('card_$index')),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('4개 이하면 가로 스크롤이 불필요하다(2x2 그대로 보임)', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildNewsLikeGrid(400, 4));
    await tester.pumpAndSettle();

    final position = Scrollable.of(
      tester.element(find.text('card_0')),
    ).position;
    expect(position.maxScrollExtent, 0);
  });

  testWidgets('5개 이상이면 오른쪽으로 스크롤해 나머지 카드를 볼 수 있다', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildNewsLikeGrid(400, 6));
    await tester.pumpAndSettle();

    final position = Scrollable.of(
      tester.element(find.text('card_0')),
    ).position;
    expect(position.maxScrollExtent, greaterThan(0));

    // 가로 스크롤이므로 왼쪽으로 드래그(오른쪽 카드 보기).
    await tester.drag(find.byType(GridView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });
}
