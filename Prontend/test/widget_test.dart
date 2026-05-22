// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows diary home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const TicketDiaryApp());
    await tester.pumpAndSettle();

    expect(find.text('티켓  추가'), findsOneWidget);
    expect(find.text('배송전'), findsWidgets);
    expect(find.text('공연전'), findsWidgets);
    expect(find.text('공연후'), findsWidgets);
  });
}
