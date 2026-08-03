import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/widgets/diary_page_flipper.dart';

void main() {
  // 테스트 기본 화면 폭은 800px이므로, 진행도 0.5(자동 완주 기준)를
  // 넘기려면 400px 이상 드래그해야 합니다.
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('왼쪽으로 절반 이상 드래그하면 onFlipForward가 호출된다', (tester) async {
    var forwardCalled = 0;
    await tester.pumpWidget(
      wrap(
        DiaryPageFlipper(
          frontPage: const ColoredBox(color: Colors.red),
          backPage: const ColoredBox(color: Colors.green),
          prevPage: const ColoredBox(color: Colors.blue),
          onFlipForward: () => forwardCalled++,
          onFlipBackward: () {},
          flipUpward: false,
        ),
      ),
    );

    await tester.drag(find.byType(DiaryPageFlipper), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(forwardCalled, 1);
  });

  testWidgets('오른쪽으로 절반 이상 드래그하면 onFlipBackward가 호출된다', (tester) async {
    var backwardCalled = 0;
    await tester.pumpWidget(
      wrap(
        DiaryPageFlipper(
          frontPage: const ColoredBox(color: Colors.red),
          backPage: const ColoredBox(color: Colors.green),
          prevPage: const ColoredBox(color: Colors.blue),
          onFlipForward: () {},
          onFlipBackward: () => backwardCalled++,
          flipUpward: false,
        ),
      ),
    );

    await tester.drag(find.byType(DiaryPageFlipper), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(backwardCalled, 1);
  });

  testWidgets('prevPage가 없으면(첫 페이지) 오른쪽 드래그가 무시된다', (tester) async {
    var backwardCalled = 0;
    await tester.pumpWidget(
      wrap(
        DiaryPageFlipper(
          frontPage: const ColoredBox(color: Colors.red),
          backPage: const ColoredBox(color: Colors.green),
          onFlipForward: () {},
          onFlipBackward: () => backwardCalled++,
          flipUpward: false,
        ),
      ),
    );

    await tester.drag(find.byType(DiaryPageFlipper), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(backwardCalled, 0);
  });

  testWidgets('onFlipForward가 없으면(마지막 페이지) 왼쪽 드래그가 무시된다', (tester) async {
    await tester.pumpWidget(
      wrap(
        DiaryPageFlipper(
          frontPage: const ColoredBox(color: Colors.red),
          backPage: const SizedBox.shrink(),
          prevPage: const ColoredBox(color: Colors.blue),
          onFlipBackward: () {},
          flipUpward: false,
        ),
      ),
    );

    await tester.drag(find.byType(DiaryPageFlipper), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // 콜백이 없으니 호출 검증 대신, 애니메이션이 시작되지 않아 정지 상태
    // (플리퍼 안에 캡처용 prevPage + frontPage 두 장)인지 확인합니다.
    // 넘어갔다면 backPage(SizedBox.shrink)만 남아 ColoredBox가 0개가 됩니다.
    expect(
      find.descendant(
        of: find.byType(DiaryPageFlipper),
        matching: find.byType(ColoredBox),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('절반 미만으로 드래그하고 놓으면 제자리로 복귀하고 콜백이 없다', (tester) async {
    var forwardCalled = 0;
    var backwardCalled = 0;
    await tester.pumpWidget(
      wrap(
        DiaryPageFlipper(
          frontPage: const ColoredBox(color: Colors.red),
          backPage: const ColoredBox(color: Colors.green),
          prevPage: const ColoredBox(color: Colors.blue),
          onFlipForward: () => forwardCalled++,
          onFlipBackward: () => backwardCalled++,
          flipUpward: false,
        ),
      ),
    );

    // 빠른 플링으로 인식되지 않도록 손을 천천히 움직입니다.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(DiaryPageFlipper)),
    );
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(-10, 0));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(forwardCalled, 0);
    expect(backwardCalled, 0);

    final gesture2 = await tester.startGesture(
      tester.getCenter(find.byType(DiaryPageFlipper)),
    );
    for (var i = 0; i < 10; i++) {
      await gesture2.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture2.up();
    await tester.pumpAndSettle();

    expect(forwardCalled, 0);
    expect(backwardCalled, 0);
  });
}
