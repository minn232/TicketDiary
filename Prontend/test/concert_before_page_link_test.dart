import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/widgets/concert_after_page_contents.dart';
import 'package:ticketdiary/widgets/concert_before_page_contents.dart';

void main() {
  testWidgets('공연 후 뒷면에는 공연 전 신문과 펼쳐보기 링크가 없다', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 560,
            height: 700,
            child: ConcertAfterPageContents(
              concertTitle: '공연 기록',
              issueNumber: 7,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(450, 350), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.text('공연 정보'), findsWidgets);
    expect(find.text('공연 전 신문'), findsNothing);
    expect(find.text('펼쳐보기 ›'), findsNothing);
    expect(find.byType(ConcertBeforeThumbnail), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('읽기 전용 공연 전 페이지는 예상 셋리 편집 버튼을 숨긴다', (tester) async {
    Future<void> pumpPage({required bool readOnly}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 560,
              height: 800,
              child: ConcertBeforePageContents(
                concertTitle: '읽기 전용 테스트',
                // concertId가 없으면 서버 조회 없이 로컬 값만 씀.
                ticketInfo: const TicketInfo(ticketId: 'ticket-1'),
                readOnly: readOnly,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpPage(readOnly: false);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);

    await pumpPage(readOnly: true);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });
}
