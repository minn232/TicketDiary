import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ticketdiary/screen/nearby_tap_screen.dart';
import 'package:ticketdiary/screen/concert_before_overlay.dart';
import 'package:ticketdiary/widgets/concert_before_page_contents.dart';
import 'package:ticketdiary/models/ticket_info.dart';
import 'support/fake_api.dart';

Future<void> animate(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('맞대기 코드 조회 실패 시 재시도하고 뒤로 닫을 수 있다', (tester) async {
    mockStorage();
    final api = installApi(
      (r) => ResponseBody.fromString(
        '{"detail":"unavailable"}',
        503,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => NearbyTapScreen.show(context, frameScale: 1),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await animate(tester);
    expect(find.text('인터넷에 연결된 상태로 한 번 열어 주세요.'), findsOneWidget);
    final before = api.requests.length;
    await tester.tap(find.text('다시 시도'));
    await animate(tester);
    expect(api.requests.length, greaterThan(before));
    expect(find.text('다시 시도'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await animate(tester);
    expect(find.byType(NearbyTapScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('공연 전 상세는 티켓 정보로 열리고 바깥 탭으로 닫힌다', (tester) async {
    mockStorage();
    installApi(sessionResponse);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => ConcertBeforeOverlay.show(
                context,
                startRect: const Rect.fromLTWH(80, 100, 250, 100),
                collapsedTicket: const Text('ticket'),
                concertTitle: '테스트 공연',
                frameScale: 1,
                readOnly: true,
                ticketInfo: TicketInfo(
                  concertName: '테스트 공연',
                  venueName: '테스트 공연장',
                  date: DateTime(2099, 8, 1),
                  price: '100000',
                  seat: 'R석',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await animate(tester);
    expect(find.byType(ConcertBeforePageContents), findsOneWidget);
    expect(
      tester
          .widget<ConcertBeforePageContents>(
            find.byType(ConcertBeforePageContents),
          )
          .ticketInfo!
          .venueName,
      '테스트 공연장',
    );
    await tester.tapAt(const Offset(5, 5));
    await animate(tester);
    expect(find.byType(ConcertBeforeOverlay), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
