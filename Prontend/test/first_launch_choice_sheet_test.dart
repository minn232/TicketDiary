import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/services/kakao_login_controller.dart';
import 'package:ticketdiary/widgets/first_launch_choice_sheet.dart';

void main() {
  testWidgets('뒤로가기·바깥 터치는 막고 로그인 취소 후 게스트 선택을 허용한다', (tester) async {
    var completed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isDismissible: false,
                enableDrag: false,
                isScrollControlled: true,
                builder: (_) => FirstLaunchChoiceSheet(
                  onKakaoLogin: (_) async =>
                      throw const KakaoLoginCancelledException(),
                  onComplete: () async {
                    completed++;
                  },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FirstLaunchChoiceSheet), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(FirstLaunchChoiceSheet), findsOneWidget);
    await tester.tap(find.text('카카오로 로그인'));
    await tester.pumpAndSettle();
    expect(completed, 0);
    expect(find.byType(FirstLaunchChoiceSheet), findsOneWidget);
    await tester.tap(find.text('게스트로 시작하기'));
    await tester.pumpAndSettle();
    expect(completed, 1);
    expect(find.byType(FirstLaunchChoiceSheet), findsNothing);
  });
}
