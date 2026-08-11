import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/models/ticket_scan.dart';
import 'package:ticketdiary/services/local_ticket_store.dart';
import 'package:ticketdiary/widgets/concert_after_page_contents.dart';

/// [ConcertAfterPageContents]가 공연 소감/사진 저장에 성공했을 때
/// [ConcertAfterPageContents.onTicketInfoChanged]로 최신 [TicketInfo]를
/// 콜백해주는지 검증합니다. 다이어리 화면(diary_screen.dart)은 이 콜백으로
/// 원본 TicketData.info를 갱신해야, 오버레이를 닫은 뒤 앱 재시작 없이도
/// 최신 내용이 보입니다(이 콜백이 없으면 오버레이 내부 로컬 상태만 바뀌고
/// 원본은 그대로라, 재방문 시 옛 데이터가 다시 보이는 버그가 있었습니다).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('공연 소감을 저장하면 onTicketInfoChanged가 최신 review로 호출된다', (
    tester,
  ) async {
    final concert = ConcertResponse(
      id: 'concert-1',
      name: '테스트 공연',
      artistName: const ['아티스트'],
      startDate: DateTime(2020, 1, 1),
      endDate: DateTime(2020, 1, 1),
      eventType: 'concert',
    );
    final created = await LocalTicketStore.instance.createTicket(
      concert: concert,
    );

    TicketInfo? callbackInfo;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConcertAfterPageContents(
            concertTitle: '테스트 공연',
            ticketInfo: TicketInfo(
              concertName: '테스트 공연',
              venueName: '테스트홀',
              price: '',
              seat: '',
              ticketId: created.id,
              review: null,
            ),
            onTicketInfoChanged: (info) => callbackInfo = info,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('공연 소감'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '정말 좋았어요');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(callbackInfo, isNotNull);
    expect(callbackInfo!.review, '정말 좋았어요');

    final stored = await LocalTicketStore.instance.listTickets();
    expect(stored.single.review, '정말 좋았어요');
  });

  testWidgets('사진을 누르면 원본이 화면에 크게 뜨고, 바깥을 누르면 닫힌다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConcertAfterPageContents(
            concertTitle: '테스트 공연',
            ticketInfo: const TicketInfo(
              concertName: '테스트 공연',
              venueName: '테스트홀',
              price: '',
              seat: '',
              ticketId: 'ticket-1',
              concertPhotoUrls: ['https://example.com/photo.png'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();

    // 확대 뷰가 하나 더 떠서 Image가 두 개(썸네일 + 원본)가 됩니다.
    expect(find.byType(Image), findsNWidgets(2));

    // 사진 바깥(여백)을 눌러 닫습니다.
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
  });
}
