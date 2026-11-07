import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/screen/splash_screen.dart';
import 'package:ticketdiary/screen/diary_screen.dart';
import 'package:ticketdiary/widgets/first_launch_choice_sheet.dart';
import 'support/fake_api.dart';

void main() {
  testWidgets('기존 게스트는 인트로 후 다이어리로 이동하고 선택창을 반복하지 않는다', (tester) async {
    mockStorage();
    final key = initNavigation();
    installApi(sessionResponse);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(FirstLaunchChoiceSheet.preferenceKey, 'guest');
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        home: const SplashScreen(),
        routes: {'/diary': (_) => const DiaryScreen()},
      ),
    );
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
    expect(find.byType(FirstLaunchChoiceSheet), findsNothing);
    expect(find.byType(SplashScreen), findsNothing);
    expect(find.byType(DiaryScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });
}
