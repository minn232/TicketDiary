import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/screen/summary_screen.dart';
import 'package:ticketdiary/widgets/summary_calendar.dart';

void main() {
  testWidgets('calendar is first and survives a four page round trip', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SummaryScreen(loader: (_) async => {})),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SummaryCalendar), findsOneWidget);
    await tester.tap(find.byTooltip('이전 달'));
    await tester.pumpAndSettle();
    final selected = tester
        .widget<SummaryCalendar>(find.byType(SummaryCalendar))
        .selection
        .value;
    for (var i = 0; i < 4; i++) {
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1500);
      await tester.pumpAndSettle();
    }
    expect(find.byType(SummaryCalendar), findsOneWidget);
    expect(
      tester
          .widget<SummaryCalendar>(find.byType(SummaryCalendar))
          .selection
          .value,
      selected,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('six week month, selected day records and year transition', (
    tester,
  ) async {
    final selection = ValueNotifier(DateTime(2026, 8, 31));
    addTearDown(selection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 480,
            child: SummaryCalendar(
              selection: selection,
              tickets: const [
                {
                  'date': '2026-08-07',
                  'concert_name': '여름 공연',
                  'price': 35000,
                  'seat': 'standing',
                },
                {
                  'date': '2026-08-07',
                  'concert_name': '두 번째 공연',
                  'price': null,
                },
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-2026-8-7')));
    await tester.pumpAndSettle();
    expect(find.text('8월 7일 · 관람 2회'), findsOneWidget);
    expect(find.text('여름 공연'), findsOneWidget);
    expect(find.text('35,000원 · 스탠딩'), findsOneWidget);
    // 월이 바뀌면 달력 장이 넘어가는 동안(300ms) 이전 장도 잠깐 같이 그려지므로 끝난 뒤 누름
    selection.value = DateTime(2026, 12, 31);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('다음 달'));
    await tester.pump();
    expect(selection.value, DateTime(2027, 1, 31));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('다음 달'));
    await tester.pump();
    expect(selection.value, DateTime(2027, 2, 28));
    expect(tester.takeException(), isNull);
  });
}
