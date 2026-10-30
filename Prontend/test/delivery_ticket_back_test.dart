import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/delivery_ticket_back.dart';

void main() {
  for (final width in [260.0, 360.0, 440.0]) {
    testWidgets('equal halves and bounded text at $width', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: width,
              height: 120,
              child: const DeliveryTicketBack(
                date: '2026.10.28',
                venue: '아주 긴 이름을 가진 테스트 공연장',
                seat: 'A구역 00열 00번 아주 긴 좌석 정보',
                price: '150,000원',
              ),
            ),
          ),
        ),
      );
      final card = tester.getRect(find.byType(DeliveryTicketBack));
      final left = tester.getRect(find.byKey(const ValueKey('delivery-left')));
      final right = tester.getRect(
        find.byKey(const ValueKey('delivery-right')),
      );
      expect(left.width, closeTo(right.width, .01));
      expect(right.right, closeTo(card.right - 12, .01));
      for (final label in ['좌석', '가격']) {
        expect(
          tester.getRect(find.text(label)).left,
          greaterThan(card.center.dx),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
