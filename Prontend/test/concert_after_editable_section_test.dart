import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/widgets/concert_after_editable_section.dart';

void main() {
  Widget page({
    String original = '기존 내용',
    bool editMode = true,
    String storageKey = 'ticket_a_information',
  }) => MaterialApp(
    home: Scaffold(
      body: ConcertAfterEditableSection(
        storageKey: storageKey,
        title: '공연 정보',
        editMode: editMode,
        loadOriginal: () async => original,
        child: Text(original),
      ),
    ),
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('edit button is below text and only visible in edit mode', (
    tester,
  ) async {
    await tester.pumpWidget(page(editMode: false));
    await tester.pumpAndSettle();
    expect(find.text('편집'), findsNothing);
    expect(find.text('기존 내용'), findsOneWidget);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('편집')).dy,
      greaterThan(tester.getBottomLeft(find.text('기존 내용')).dy),
    );
    await tester.pumpWidget(page(editMode: false));
    await tester.pumpAndSettle();
    expect(find.text('편집'), findsNothing);
  });

  testWidgets('edits survive remount; deleting all text stays empty', (
    tester,
  ) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.text('편집'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '수정한 내용\n추가한 내용');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('수정한 내용\n추가한 내용'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('수정한 내용\n추가한 내용'), findsOneWidget);
    await tester.tap(find.text('편집'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('내용 지우기'));
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('기존 내용'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ticket_a_information'), '');
  });

  testWidgets('cancel preserves original and does not create override', (
    tester,
  ) async {
    const storageKey = 'ticket_a_information_cancel';
    await tester.pumpWidget(page(storageKey: storageKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('편집'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '취소할 내용');
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(find.text('기존 내용'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(storageKey), isFalse);
  });
}
