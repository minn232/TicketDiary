import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/widgets/concert_after_text_canvas.dart';

void main() {
  testWidgets('후기 박스는 꾹 눌러 삭제하고 재진입해도 복구되지 않는다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    Widget buildPage() => MaterialApp(
      home: Scaffold(
        body: ConcertAfterTextCanvas(
          storageKey: 'delete_test',
          initialReview: '삭제할 기록',
          width: 390,
          minHeight: 600,
          editMode: true,
          obstacles: const [],
          memos: const [],
          onReviewChanged: (_) async {},
        ),
      ),
    );
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('after_text_original_review')),
    );
    await tester.pumpAndSettle();
    expect(find.text('텍스트 박스 삭제'), findsOneWidget);
    await tester.tap(find.text('텍스트 박스 삭제'));
    await tester.pumpAndSettle();
    expect(find.text('삭제할 기록'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    expect(find.text('삭제할 기록'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Widget page({String review = '', bool editMode = false}) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 390,
          height: 600,
          child: ConcertAfterTextCanvas(
            storageKey: review.isEmpty ? 'test' : 'legacy_$review',
            initialReview: review,
            width: 390,
            minHeight: 600,
            editMode: editMode,
            obstacles: const [
              Rect.fromLTWH(0, 0, 390, 70),
              Rect.fromLTWH(20, 90, 160, 140),
            ],
            memos: const [
              Positioned(
                left: 20,
                top: 90,
                width: 160,
                height: 140,
                child: ColoredBox(
                  key: ValueKey('memo_obstacle'),
                  color: Colors.brown,
                ),
              ),
            ],
            onReviewChanged: (_) async {},
          ),
        ),
      ),
    ),
  );
  Future<void> doubleTap(WidgetTester tester, Offset p) async {
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tapAt(p);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(p);
    await tester.pumpAndSettle();
  }

  testWidgets('빈 곳 더블탭 생성, 외부 탭 잠금, 더블탭 재편집, 여러 박스 저장', (tester) async {
    await tester.pumpWidget(page(editMode: true));
    await tester.pumpAndSettle();
    await doubleTap(tester, const Offset(205, 100));
    expect(find.byType(EditableText), findsOneWidget);
    await tester.enterText(find.byType(EditableText), '첫 번째 기록');
    await tester.tapAt(const Offset(350, 550));
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsNothing);
    await tester.tapAt(const Offset(205, 100));
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsNothing);
    await doubleTap(tester, const Offset(205, 100));
    expect(find.byType(EditableText), findsOneWidget);
    await tester.tapAt(const Offset(350, 550));
    await tester.pumpAndSettle();
    await doubleTap(tester, const Offset(24, 320));
    await tester.enterText(find.byType(EditableText), '두 번째 기록');
    await tester.tapAt(const Offset(350, 550));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('after_text_original_review')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page(editMode: true));
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsNothing);
    expect(find.byType(EditableText), findsNothing);
  });

  testWidgets('긴 텍스트는 박스 안에서 줄바꿈되고 내부 스크롤하지 않는다', (tester) async {
    await tester.pumpWidget(page(review: '이전 후기', editMode: true));
    await tester.pumpAndSettle();
    await doubleTap(
      tester,
      tester.getCenter(
        find.byKey(const ValueKey('after_text_original_review')),
      ),
    );
    final shortSize = tester.getSize(find.byType(EditableText));
    await tester.enterText(
      find.byType(EditableText),
      List.filled(40, '길게 남기는 공연 기록').join('\n'),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(EditableText)).height,
      greaterThan(shortSize.height),
    );
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.scrollPhysics, isA<NeverScrollableScrollPhysics>());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('잠금모드에서는 후기 박스를 꾹 눌러도 삭제 메뉴가 뜨지 않는다', (tester) async {
    await tester.pumpWidget(page(review: '잠금 후기'));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('after_text_original_review')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('텍스트 박스 삭제'), findsNothing);
    expect(
      find.byKey(const ValueKey('after_text_original_review')),
      findsOneWidget,
    );
  });

  testWidgets('잠금모드에서는 후기 박스 더블탭으로도 편집되지 않는다', (tester) async {
    await tester.pumpWidget(page(review: '잠금 편집 차단'));
    await tester.pumpAndSettle();
    await doubleTap(
      tester,
      tester.getCenter(
        find.byKey(const ValueKey('after_text_original_review')),
      ),
    );
    expect(find.byType(EditableText), findsNothing);
    expect(
      find.byKey(const ValueKey('after_text_original_review')),
      findsOneWidget,
    );
  });

  testWidgets('편집모드에서만 후기 박스를 꾹 눌러 삭제할 수 있다', (tester) async {
    await tester.pumpWidget(page(review: '편집 후기', editMode: true));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey('after_text_original_review')),
    );
    await tester.pumpAndSettle();
    expect(find.text('텍스트 박스 삭제'), findsOneWidget);
  });
}
