import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/screen/concert_after_overlay.dart';
import 'package:ticketdiary/widgets/concert_after_page_contents.dart';

/// 공연후 오버레이에서 키보드가 올라와도(하단 인셋) 페이지 크기가 그대로인지 검증.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('키보드가 뜨고 내려가도 공연후 페이지 크기가 바뀌지 않는다', (tester) async {
    tester.view.physicalSize = const Size(800, 1280) * 2;
    tester.view.devicePixelRatio = 2;
    // 하단 제스처 바 영역(안전 여백).
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => ConcertAfterOverlay.show(
                  context,
                  startRect: const Rect.fromLTWH(100, 100, 200, 120),
                  collapsedTicket: const SizedBox(),
                  concertTitle: '테스트 공연',
                  frameScale: 1.8,
                  ticketInfo: const TicketInfo(concertName: '테스트 공연'),
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    final before = tester.getSize(find.byType(ConcertAfterPageContents));

    // 키보드가 올라오면 플랫폼은 하단 padding을 0으로, viewInsets를 키보드 높이로 줌.
    tester.view.viewInsets = const FakeViewPadding(bottom: 1000);
    tester.view.padding = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ConcertAfterPageContents)), before);

    tester.view.resetViewInsets();
    tester.view.padding = const FakeViewPadding(bottom: 48);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ConcertAfterPageContents)), before);
  });
}
