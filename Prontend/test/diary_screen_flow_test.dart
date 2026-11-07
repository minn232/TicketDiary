import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/screen/diary_screen.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/services/auth_service.dart';
import 'support/fake_api.dart';

void main() {
  testWidgets('서버 티켓을 다이어리에 표시하고 추가 메뉴를 열고 닫는다', (tester) async {
    mockStorage();
    final navigator = initNavigation();
    final api = installApi(
      (r) => r.path == '/tickets'
          ? [
              ticketJson('delivery', 'before_delivery'),
              ticketJson('future', 'before_concert'),
              ticketJson('past', 'after_concert'),
            ]
          : sessionResponse(r),
    );
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await AuthService.instance.ensureSession();
      await DiaryScreen.preloadTickets();
    });
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const DiaryScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(DiaryPageFrame), findsOneWidget);
    expect(find.textContaining('공연 delivery'), findsWidgets);
    expect(find.textContaining('공연 future'), findsWidgets);
    expect(api.requests.where((r) => r.path == '/tickets'), isNotEmpty);
    expect(find.text('1 / 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add_ticket_button')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('카메라'), findsWidgets);
    expect(find.text('갤러리'), findsWidgets);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(DiaryScreen), findsOneWidget);
    tester.view.physicalSize = const Size(2560, 1600);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(DiaryPageFrame), findsOneWidget);
    expect(find.textContaining('공연 future'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
  });
}
