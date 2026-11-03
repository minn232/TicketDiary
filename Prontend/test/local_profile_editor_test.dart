import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/widgets/local_profile_editor.dart';

void main() {
  testWidgets('닉네임을 기기에 저장하고 다른 계정에는 적용하지 않는다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    Future<void> show(String id) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocalProfileEditor(
              key: ValueKey(id),
              userId: id,
              nickname: '기존 이름',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show('user-a');
    await tester.tap(find.byTooltip('닉네임 수정'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '새 닉네임');
    await tester.pump();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('새 닉네임'), findsOneWidget);
    await show('user-b');
    expect(find.text('기존 이름'), findsOneWidget);
    await show('user-a');
    expect(find.text('새 닉네임'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
