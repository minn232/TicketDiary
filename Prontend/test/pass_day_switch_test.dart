import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/screen/concert_after_overlay.dart';
import 'package:ticketdiary/widgets/pass_day_switcher.dart';

/// 2일권/3일권 공연후 페이지에서 다른 날짜를 누르면 그 날 번호를 돌려주며 닫히는지 검증.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('다른 관람일을 누르면 그 날 번호를 돌려주고 닫힌다', (tester) async {
    tester.view.physicalSize = const Size(800, 1280) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    int? result = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await ConcertAfterOverlay.show(
                    context,
                    startRect: const Rect.fromLTWH(100, 100, 200, 120),
                    collapsedTicket: const SizedBox(),
                    concertTitle: '테스트 페스티벌',
                    frameScale: 1.8,
                    ticketInfo: const TicketInfo(concertName: '테스트 페스티벌'),
                    passDays: PassDayTabs(
                      days: [
                        DateTime.utc(2030, 8, 1),
                        DateTime.utc(2030, 8, 2),
                        DateTime.utc(2030, 8, 3),
                      ],
                      selected: 0,
                    ),
                  );
                },
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    expect(find.byType(PassDaySwitcher), findsOneWidget);
    // 지금 보는 날은 눌러도 그대로
    await tester.tap(find.textContaining('08.01'));
    await tester.pumpAndSettle();
    expect(find.byType(PassDaySwitcher), findsOneWidget);

    await tester.tap(find.textContaining('08.03'));
    await tester.pumpAndSettle();
    expect(result, 2);
    expect(find.byType(PassDaySwitcher), findsNothing);
  });

  testWidgets('묶음이 아니면 날짜 표시가 없다', (tester) async {
    tester.view.physicalSize = const Size(800, 1280) * 2;
    tester.view.devicePixelRatio = 2;
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

    expect(find.byType(PassDaySwitcher), findsNothing);
  });
}
