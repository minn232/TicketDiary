import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/feather_ticket_arrival.dart';

void main() {
  testWidgets('화면 위에서 출발해 좌우로 흔들리고 6초에 정확히 착지한다', (tester) async {
    var completed = 0;
    const target = Rect.fromLTWH(150, 400, 250, 100);
    const ticketKey = ValueKey('falling-ticket');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeatherTicketArrival(
            target: target,
            onComplete: () => completed++,
            child: const ColoredBox(key: ticketKey, color: Colors.white),
          ),
        ),
      ),
    );
    final initial = tester.getRect(find.byKey(ticketKey));
    expect(initial.bottom, lessThan(0));
    double scale() => tester
        .widget<Transform>(find.byKey(const ValueKey('arrival-scale')))
        .transform
        .storage[0];
    double darkness() => tester
        .widget<ColoredBox>(find.byKey(const ValueKey('arrival-dimming')))
        .color
        .a;
    expect(scale(), 2);
    expect(darkness(), closeTo(.65, .01));
    var previousScale = scale();
    final positions = <double>[];
    var previousY = initial.top;
    for (var i = 0; i < 9; i++) {
      await tester.pump(const Duration(milliseconds: 600));
      final position = tester.getTopLeft(find.byKey(ticketKey));
      positions.add(tester.getCenter(find.byKey(ticketKey)).dx);
      expect(scale(), lessThan(previousScale));
      previousScale = scale();
      expect(position.dy, greaterThan(previousY));
      previousY = position.dy;
      expect(completed, 0);
      expect(darkness(), closeTo(.65, .01));
      expect(find.byKey(const ValueKey('arrival-impact')), findsNothing);
    }
    expect(positions.any((x) => x < target.center.dx), isTrue);
    expect(positions.any((x) => x > target.center.dx), isTrue);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.getRect(find.byKey(ticketKey)), target);
    expect(scale(), 1);
    expect(darkness(), closeTo(.65, .01));
    // 6초 착지 후 700ms 동안 먼지가 퍼지는 동안 티켓은 제자리에 있습니다.
    await tester.pump(const Duration(milliseconds: 1));
    expect(completed, 0);
    expect(find.byKey(const ValueKey('arrival-impact')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.getRect(find.byKey(ticketKey)), target);
    expect(darkness(), greaterThan(0));
    expect(darkness(), lessThan(.65));
    expect(find.byKey(const ValueKey('arrival-impact')), findsOneWidget);
    expect(completed, 0);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('arrival-impact')), findsNothing);
    expect(darkness(), 0);
    expect(completed, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(completed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('화면을 나가면 낙하 타이머와 완료 콜백이 취소된다', (tester) async {
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: FeatherTicketArrival(
          target: const Rect.fromLTWH(20, 300, 200, 80),
          onComplete: () => completed = true,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
    expect(completed, isFalse);
    expect(tester.takeException(), isNull);
  });
}
