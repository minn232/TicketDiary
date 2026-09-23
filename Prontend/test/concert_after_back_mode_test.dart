import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/screen/concert_after_overlay.dart';
import 'package:ticketdiary/widgets/concert_after_page_contents.dart';
import 'package:ticketdiary/widgets/setlist_editor_sheet.dart';

// 뒷면엔 편집 모드가 없음 - 셋리스트는 제목 옆 "편집" 버튼으로 바로 편집.
void main() {
  testWidgets(
    'back long press does not enter edit mode and flip exits edit mode',
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

      // 앞면에서 편집 모드로.
      await tester.longPressAt(const Offset(500, 450));
      await tester.pumpAndSettle();
      expect(find.text('편집 모드'), findsOneWidget);

      // 뒷면으로 넘기면 편집 모드 해제.
      await tester.dragFrom(const Offset(450, 350), const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(find.text('공연 정보'), findsOneWidget);
      expect(find.text('편집 모드'), findsNothing);

      // 뒷면을 길게 눌러도 편집 모드가 되지 않음.
      await tester.longPressAt(const Offset(280, 35));
      await tester.pumpAndSettle();
      expect(find.text('편집 모드'), findsNothing);
      expect(find.text('공연 정보'), findsOneWidget);

      // 다시 앞면: 잠금 상태.
      await tester.dragFrom(const Offset(100, 350), const Offset(220, 0));
      await tester.pumpAndSettle();
      expect(find.text('공연 정보'), findsNothing);
      expect(find.text('잠금 (꾹 눌러 편집)'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'back setlist edit button opens editor and stays on back page in overlay',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    unawaited(
                      ConcertAfterOverlay.show(
                        context,
                        startRect: const Rect.fromLTWH(160, 160, 160, 220),
                        collapsedTicket: const SizedBox(
                          width: 160,
                          height: 220,
                        ),
                        concertTitle: '오버레이 편집 테스트',
                        frameScale: 1,
                        ticketInfo: const TicketInfo(
                          concertName: '오버레이 편집 테스트',
                          ticketId: 't1',
                        ),
                      ),
                    );
                  },
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(450, 350), const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(find.text('공연 정보'), findsOneWidget);

      // 편집 모드 없이 제목 옆 "편집"으로 바로.
      await tester.tap(find.byTooltip('셋리스트 편집'));
      await tester.pumpAndSettle();
      expect(find.byType(SetlistEditorSheet), findsOneWidget);
      Navigator.of(tester.element(find.byType(SetlistEditorSheet))).pop();
      await tester.pumpAndSettle();

      expect(find.text('공연 정보'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
