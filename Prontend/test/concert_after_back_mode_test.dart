import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/widgets/concert_after_page_contents.dart';

void main() {
  testWidgets(
    'back long press toggles mode after flip and mode survives return',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 560,
              height: 700,
              child: ConcertAfterPageContents(concertTitle: '모드 전환 테스트'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(450, 350), const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(find.text('공연 정보'), findsOneWidget);
      expect(find.text('잠금 (꾹 눌러 편집)'), findsOneWidget);

      await tester.longPressAt(const Offset(280, 35));
      await tester.pumpAndSettle();
      expect(find.text('편집 모드'), findsOneWidget);
      expect(find.text('편집'), findsNWidgets(3));

      await tester.longPressAt(const Offset(280, 35));
      await tester.pumpAndSettle();
      expect(find.text('잠금 (꾹 눌러 편집)'), findsOneWidget);
      expect(find.text('편집'), findsNothing);

      await tester.longPressAt(const Offset(280, 35));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(100, 350), const Offset(220, 0));
      await tester.pumpAndSettle();
      expect(find.text('공연 정보'), findsNothing);
      expect(find.text('편집 모드'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
