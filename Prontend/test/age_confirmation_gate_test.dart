import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/widgets/age_confirmation_gate.dart';

void main() {
  testWidgets('미확인과 아니요는 앱 로딩을 차단하고 예를 선택하면 저장 후 시작한다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var builds = 0;
    Widget app() => MaterialApp(
      home: AgeConfirmationGate(
        builder: (_) {
          builds++;
          return const Scaffold(body: Text('앱 시작'));
        },
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('만 14세 이상입니까?'), findsOneWidget);
    expect(builds, 0);
    await tester.tap(find.text('아니요'));
    await tester.pumpAndSettle();
    expect(find.text('만 14세 이상만 이용할 수 있어요'), findsOneWidget);
    expect(builds, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AgeConfirmationGate.preferenceKey), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(builds, 0);
    await tester.tap(find.text('다시 확인하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('예'));
    await tester.pumpAndSettle();
    expect(find.text('앱 시작'), findsOneWidget);
    expect(prefs.getBool(AgeConfirmationGate.preferenceKey), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('앱 시작'), findsOneWidget);
    expect(find.text('만 14세 이상입니까?'), findsNothing);
  });
}
