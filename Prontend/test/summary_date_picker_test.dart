import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/summary_date_picker.dart';

void main() {
  testWidgets('fast scrolling stops at earliest attended date', (tester) async {
    final dates = [
      DateTime(2024, 6, 7),
      DateTime(2024, 9, 20),
      DateTime(2026, 11, 9),
    ];
    var selected = dates.last;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 250,
            child: SummaryDatePicker(
              dates: dates,
              initialDate: selected,
              onChanged: (date) => selected = date,
            ),
          ),
        ),
      ),
    );
    final wheels = find.byType(ListWheelScrollView);
    await tester.fling(wheels.at(0), const Offset(0, 1000), 5000);
    await tester.pumpAndSettle();
    expect(selected.year, 2024);
    await tester.fling(wheels.at(1), const Offset(0, 1000), 5000);
    await tester.pumpAndSettle();
    await tester.fling(wheels.at(2), const Offset(0, 1000), 5000);
    await tester.pumpAndSettle();
    expect(selected, dates.first);
    expect(find.text('2023년'), findsNothing);
    expect(find.text('5월'), findsNothing);
    expect(find.text('6일'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
