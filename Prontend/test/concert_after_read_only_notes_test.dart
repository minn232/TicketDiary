import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/widgets/concert_after_text_canvas.dart';
import 'package:ticketdiary/widgets/concert_after_page_contents.dart';
import 'package:ticketdiary/models/ticket_info.dart';

Future<void> doubleTap(WidgetTester tester, Offset point) async {
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(point);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final editMode in [false, true]) {
    testWidgets('읽기 전용 메모는 사진 편집 모드 $editMode 에서도 입력·저장되지 않는다', (tester) async {
      var saves = 0;
      var layouts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConcertAfterTextCanvas(
              storageKey: 'readonly',
              initialReview: '기존 기록',
              width: 390,
              minHeight: 600,
              editMode: editMode,
              readOnly: true,
              obstacles: const [],
              memos: const [],
              onReviewChanged: (_) async {
                saves++;
              },
              onTextsChanged: (_) {
                layouts++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('기존 기록'), findsNothing);
      await doubleTap(tester, const Offset(200, 150));
      expect(find.byType(EditableText), findsNothing);
      await doubleTap(tester, const Offset(200, 150));
      expect(find.byType(EditableText), findsNothing);
      await tester.longPressAt(const Offset(200, 150));
      await tester.pumpAndSettle();
      expect(find.text('텍스트 박스 삭제'), findsNothing);
      expect(find.text('기존 기록'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(layouts, 0);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    });
  }

  testWidgets('공연 후 페이지의 사진 편집 모드에서도 자유 텍스트 입력이 열리지 않는다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.only(top: 80),
            child: SizedBox(
              width: 400,
              height: 500,
              child: ConcertAfterPageContents(
                concertTitle: '읽기 전용 기록',
                ticketInfo: TicketInfo(review: '보존할 후기'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ConcertAfterTextCanvas>(find.byType(ConcertAfterTextCanvas))
          .readOnly,
      isTrue,
    );
    await tester.longPressAt(const Offset(30, 520));
    await tester.pumpAndSettle();
    expect(find.text('편집 모드'), findsOneWidget);
    await doubleTap(tester, const Offset(40, 490));
    expect(find.byType(EditableText), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
