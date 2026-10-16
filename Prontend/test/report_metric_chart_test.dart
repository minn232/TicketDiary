import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/report_metric_chart.dart';

void main() {
  testWidgets('compact report card keeps values visible without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 112,
              child: ReportMetricChart(
                rows: [('평균', 120000, '120,000원'), ('최고', 240000, '240,000원')],
                note: '최고 지출 공연: 긴 공연 이름의 테스트 공연',
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('120,000원'), findsOneWidget);
    expect(find.text('240,000원'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    expect(find.byType(Scrollable), findsNothing);
  });
  testWidgets('zero and large values fit a narrow report without scrolling', (
    tester,
  ) async {
    for (final values in [
      <(String, double, String)>[('사진', 0, '0장')],
      <(String, double, String)>[
        ('평균', 120000, '120,000원'),
        ('최고', 240000, '240,000원'),
      ],
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                height: 360,
                child: ReportMetricChart(rows: values, note: '정보가 없는 항목은 제외'),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollable), findsNothing);
      for (final value in values) {
        expect(find.text(value.$3), findsOneWidget);
      }
    }
  });
}
