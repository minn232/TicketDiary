import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/widgets/concert_after_page_contents.dart';
import 'package:ticketdiary/widgets/concert_before_page_contents.dart';

// 공연 후 페이지 뒷면 공연 정보의 "공연 전 신문" 썸네일 - 누르면 공연 전 페이지를 읽기 전용으로 다시 엶.
void main() {
  // 기본 테스트 화면(800x600)보다 페이지가 길어서 썸네일이 화면 밖에 그려지지 않게 키움.
  void enlargeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpAfterPage(
    WidgetTester tester, {
    Future<void> Function(Rect, Widget)? onOpenBeforePage,
  }) async {
    enlargeView(tester);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 560,
            height: 700,
            child: ConcertAfterPageContents(
              concertTitle: '공연 전 신문 테스트',
              issueNumber: 7,
              onOpenBeforePage: onOpenBeforePage,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 뒷면으로 넘김.
    await tester.dragFrom(const Offset(450, 350), const Offset(-220, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('뒷면 공연 정보에 공연 전 신문 썸네일이 있고 누르면 열기를 요청한다', (tester) async {
    Rect? openedFrom;
    await pumpAfterPage(
      tester,
      onOpenBeforePage: (startRect, collapsed) async => openedFrom = startRect,
    );

    expect(find.text('공연 전 신문'), findsOneWidget);
    expect(find.text('제 7 호'), findsOneWidget);
    expect(find.text('펼쳐보기 ›'), findsOneWidget);
    // 공연 정보 칸은 칸 안에서 스크롤됨 - 썸네일이 보이게 내린 뒤 누름.
    await tester.ensureVisible(find.byType(ConcertBeforeThumbnail));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ConcertBeforeThumbnail));
    await tester.pumpAndSettle();

    expect(openedFrom, isNotNull);
    expect(openedFrom!.width, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('여는 콜백이 없으면 썸네일은 보이기만 하고 펼쳐보기가 없다', (tester) async {
    await pumpAfterPage(tester);

    expect(find.byType(ConcertBeforeThumbnail), findsOneWidget);
    expect(find.text('펼쳐보기 ›'), findsNothing);

    await tester.pumpWidget(const SizedBox());
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
