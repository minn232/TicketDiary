import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/screen/summary_screen.dart';
import 'package:ticketdiary/widgets/summary_calendar.dart';
import 'package:ticketdiary/widgets/summary_report.dart';

const sample = <String, dynamic>{
  'concert_count': 12,
  'total_spent': 1280000,
  'total_runtime_minutes': 1560,
  'top_genres': ['록/밴드'],
};

Future<void> pumpScreen(WidgetTester tester, SummaryJsonLoader loader) async {
  tester.view.physicalSize = const Size(800, 1700);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: SummaryScreen(loader: loader)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('calendar and all three periods use a two-page report', (
    tester,
  ) async {
    final requested = <String>[];
    await pumpScreen(tester, (period) async {
      requested.add(period);
      return sample;
    });
    expect(find.byType(SummaryCalendar), findsOneWidget);
    for (final label in ['캘린더', '6개월 보고서', '1년 보고서']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.byType(SummaryReport), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('관람한 공연'), findsOneWidget);
      await tester.tap(find.byTooltip('다음 보고서'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('관람 아티스트'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('전체 보고서'));
    await tester.pumpAndSettle();
    expect(find.byType(SummaryCalendar), findsOneWidget);
    expect(requested, ['all', '6m', '1y', 'all']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets(
    'latest request wins and failed refresh retains previous report',
    (tester) async {
      final pending = <String, Completer<Map<String, dynamic>>>{};
      var initial = true;
      await pumpScreen(tester, (period) {
        if (initial) {
          initial = false;
          return Future.value(sample);
        }
        return (pending[period] = Completer<Map<String, dynamic>>()).future;
      });
      await tester.tap(find.text('캘린더'));
      await tester.pump();
      await tester.tap(find.text('6개월 보고서'));
      await tester.pump();
      pending['1y']!.complete({...sample, 'total_spent': 200000});
      await tester.pump();
      pending['6m']!.complete({...sample, 'total_spent': 300000});
      await tester.pumpAndSettle();
      expect(find.text('200,000원'), findsOneWidget);
      expect(find.text('300,000원'), findsNothing);
      await tester.tap(find.text('1년 보고서'));
      await tester.pump();
      // 전체 기간은 처음(캘린더) 받아둔 값이 있어 다른 기간 숫자 대신 그 값을 바로 그림
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1,280,000원'), findsOneWidget);
      expect(find.text('200,000원'), findsNothing);
      pending['all']!.completeError(Exception('network'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1년 보고서'), findsOneWidget);
      expect(find.text('200,000원'), findsOneWidget);
      expect(find.textContaining('이전 값을'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
  );
}
