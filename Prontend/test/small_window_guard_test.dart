import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/small_window_guard.dart';

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const MaterialApp(
      home: Stack(
        children: [
          Center(child: Text('다이어리')),
          Positioned.fill(child: SmallWindowGuard()),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('폰 세로·가로 크기에서는 안내가 뜨지 않는다', (tester) async {
    for (final size in const [Size(360, 740), Size(740, 360)]) {
      await _pump(tester, size);
      expect(find.text('화면이 너무 좁아요'), findsNothing);
    }
  });

  testWidgets('분할 화면처럼 폭이나 높이가 너무 작으면 안내로 덮는다', (tester) async {
    for (final size in const [Size(250, 740), Size(800, 280)]) {
      await _pump(tester, size);
      expect(find.text('화면이 너무 좁아요'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
