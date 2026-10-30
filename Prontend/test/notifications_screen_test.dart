import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/notification_display.dart';
import 'package:ticketdiary/models/notification_model.dart';
import 'package:ticketdiary/screen/notifications_screen.dart';
import 'package:ticketdiary/services/notifications_service.dart';
import 'package:ticketdiary/widgets/diary_route.dart';
import 'package:ticketdiary/widgets/tab_nav_coordinator.dart';

/// 실제 네트워크 없이 목록/읽음/삭제 호출을 흉내내는 페이크. list()가
/// 반환하는 목록은 내부 상태를 그대로 반영해, 삭제 후 다시 열어도
/// 일관되게 동작합니다.
class _FakeNotificationsService extends NotificationsService {
  _FakeNotificationsService(List<NotificationModel> initial)
    : _items = List.of(initial);

  final List<NotificationModel> _items;
  final List<String> markReadCalls = [];
  final List<String> deleteCalls = [];
  int markAllReadCalls = 0;

  @override
  Future<void> markAllRead() async => markAllReadCalls++;

  @override
  Future<List<NotificationModel>> list() async => List.of(_items);

  @override
  Future<void> markRead(String id) async => markReadCalls.add(id);

  @override
  Future<void> delete(String id) async {
    deleteCalls.add(id);
    _items.removeWhere((e) => e.id == id);
  }
}

NotificationModel _item({
  required String id,
  required String title,
  bool isRead = false,
  String type = 'general',
  String? ticketId,
  String? concertId,
  DateTime? scheduledAt,
}) {
  return NotificationModel(
    id: id,
    ticketId: ticketId,
    type: type,
    title: title,
    body: '$title 본문입니다.',
    isRead: isRead,
    scheduledAt: scheduledAt ?? DateTime(2026, 9, 7, 10, 30),
    concertId: concertId,
  );
}

Future<void> _openOverlay(
  WidgetTester tester,
  NotificationsService service,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => NotificationsScreen.show(
                ctx,
                frameScale: 1.0,
                service: service,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('알림 목록이 예외 없이 열리고 항목/안읽음 뱃지가 보인다', (tester) async {
    final service = _FakeNotificationsService([
      _item(id: '1', title: '공연 하루 전이에요', isRead: false),
      _item(id: '2', title: '티켓팅 시작 알림', isRead: true),
    ]);

    await _openOverlay(tester, service);

    expect(tester.takeException(), isNull);
    expect(find.text('알림함'), findsOneWidget);
    expect(find.text('공연 하루 전이에요'), findsOneWidget);
    expect(find.text('티켓팅 시작 알림'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
  });

  testWidgets('알림이 없으면 빈 상태 문구가 보인다', (tester) async {
    final service = _FakeNotificationsService(const []);

    await _openOverlay(tester, service);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('아직 도착한 알림이 없어요'), findsOneWidget);
  });

  testWidgets('항목을 누르면 읽음 처리가 호출된다', (tester) async {
    final service = _FakeNotificationsService([
      _item(id: '1', title: '공연 하루 전이에요', isRead: false),
    ]);

    await _openOverlay(tester, service);
    await tester.tap(find.text('공연 하루 전이에요'));
    await tester.pumpAndSettle();

    expect(service.markReadCalls, ['1']);
  });

  testWidgets('왼쪽으로 스와이프하면 삭제되고 예외 없이 트리에서 사라진다', (tester) async {
    final service = _FakeNotificationsService([
      _item(id: '1', title: '공연 하루 전이에요', isRead: false),
      _item(id: '2', title: '티켓팅 시작 알림', isRead: true),
    ]);

    await _openOverlay(tester, service);

    await tester.drag(find.text('공연 하루 전이에요'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(service.deleteCalls, ['1']);
    expect(find.text('공연 하루 전이에요'), findsNothing);
    expect(find.text('티켓팅 시작 알림'), findsOneWidget);
  });

  testWidgets('배경(위쪽 딤 영역)을 누르면 닫힌다', (tester) async {
    final service = _FakeNotificationsService([
      _item(id: '1', title: '공연 하루 전이에요', isRead: false),
    ]);

    await _openOverlay(tester, service);
    expect(find.text('알림함'), findsOneWidget);

    // 패널은 화면 아래 90%만 차지하므로, 맨 위쪽(예: y=10)은 딤 배경입니다.
    await tester.tapAt(const Offset(200, 10));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('알림함'), findsNothing);
  });

  // [백엔드 수정]
  // 뒤로가기 키가 기본 팝(페이드)으로 바로 닫혀서 X버튼/드래그(슬라이드다운)와
  // 다르게 보이던 것을 PopScope로 통일한 회귀 테스트.
  testWidgets('뒤로가기를 눌러도 X버튼/드래그와 같은 방식으로 닫힌다', (tester) async {
    final service = _FakeNotificationsService([
      _item(id: '1', title: '공연 하루 전이에요', isRead: false),
    ]);

    await _openOverlay(tester, service);
    expect(find.text('알림함'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('알림함'), findsNothing);
  });

  testWidgets('창이 다 올라온 뒤 알림 카드가 위에서부터 차례로 나타난다', (tester) async {
    final service = _FakeNotificationsService([
      _item(id: '1', title: '첫 번째 알림'),
      _item(id: '2', title: '두 번째 알림'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => NotificationsScreen.show(
                ctx,
                frameScale: 1.0,
                service: service,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // 창이 올라오는 시간(0.32초)이 끝나고 카드 연출이 막 시작된 시점
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 340));
    await tester.pump(const Duration(milliseconds: 100));

    double opacityOf(String text) => tester
        .widget<Opacity>(
          find
              .ancestor(of: find.text(text), matching: find.byType(Opacity))
              .first,
        )
        .opacity;
    // 앞 카드가 먼저 떠오름
    expect(opacityOf('첫 번째 알림'), greaterThan(opacityOf('두 번째 알림')));

    await tester.pumpAndSettle();
    expect(opacityOf('첫 번째 알림'), 1.0);
    expect(opacityOf('두 번째 알림'), 1.0);
  });

  testWidgets('제목줄(알림함 글자)을 아래로 끌어도 닫히고, 조금만 끌면 제자리로 돌아온다', (tester) async {
    final service = _FakeNotificationsService([_item(id: '1', title: '알림')]);
    await _openOverlay(tester, service);

    await tester.drag(find.text('알림함'), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(find.text('알림함'), findsOneWidget);

    await tester.fling(find.text('알림함'), const Offset(0, 300), 1500);
    await tester.pumpAndSettle();
    expect(find.text('알림함'), findsNothing);
  });

  test('상대 시간과 묶음 제목', () {
    final now = DateTime(2026, 10, 28, 15, 0);
    expect(
      notificationTimeLabel(DateTime(2026, 10, 28, 14, 59, 30), now),
      '방금',
    );
    expect(notificationTimeLabel(DateTime(2026, 10, 28, 14, 20), now), '40분 전');
    expect(notificationTimeLabel(DateTime(2026, 10, 28, 9, 0), now), '6시간 전');
    expect(
      notificationTimeLabel(DateTime(2026, 10, 27, 9, 5), now),
      '어제 09:05',
    );
    expect(notificationTimeLabel(DateTime(2026, 10, 24, 9, 0), now), '4일 전');
    expect(notificationTimeLabel(DateTime(2026, 9, 7, 9, 0), now), '9월 7일');
    expect(
      notificationTimeLabel(DateTime(2025, 9, 7, 9, 0), now),
      '2025.09.07',
    );

    expect(notificationGroupLabel(DateTime(2026, 10, 28, 1, 0), now), '오늘');
    expect(notificationGroupLabel(DateTime(2026, 10, 27, 23, 0), now), '어제');
    expect(notificationGroupLabel(DateTime(2026, 10, 22, 9, 0), now), '이번 주');
    expect(notificationGroupLabel(DateTime(2026, 10, 20, 9, 0), now), '이전');

    expect(NotificationKind.of('day_before').label, '공연 전날');
    expect(NotificationKind.of('day_before').opensTicket, isTrue);
    expect(NotificationKind.of('new_concert').opensTicket, isFalse);
    expect(NotificationKind.of('unknown').label, '알림');

    // 오늘 받은 알림은 그대로, 지난 알림의 오늘/내일은 실제 날짜로(전날 알림은 다음 날이 공연일)
    expect(
      notificationInboxBody(
        'day_before',
        '내일 공연이에요.',
        DateTime(2026, 10, 28, 9),
        now,
      ),
      '내일 공연이에요.',
    );
    expect(
      notificationInboxBody(
        'day_before',
        '내일 19:00 올림픽공원에서 공연이 있어요.',
        DateTime(2026, 10, 27, 9),
        now,
      ),
      '10월 28일(수) 19:00 올림픽공원에서 공연이 있어요.',
    );
    expect(
      notificationInboxBody(
        'concert_day',
        '오늘 공연 날이에요.',
        DateTime(2026, 10, 25, 9),
        now,
      ),
      '10월 25일(일) 공연 날이에요.',
    );
    // 날짜와 상관없는 알림은 안 건드림
    expect(
      notificationInboxBody(
        'new_concert',
        '오늘의 소식',
        DateTime(2026, 10, 25, 9),
        now,
      ),
      '오늘의 소식',
    );
  });

  testWidgets('종류 태그와 날짜 묶음 제목이 보인다', (tester) async {
    final service = _FakeNotificationsService([
      _item(
        id: '1',
        title: '오늘 공연명',
        type: 'concert_day',
        scheduledAt: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
      _item(id: '2', title: '예전 공연명', type: 'ticketing_day'),
    ]);
    await _openOverlay(tester, service);

    expect(find.text('오늘'), findsOneWidget);
    expect(find.text('이전'), findsOneWidget);
    expect(find.text('공연 당일'), findsOneWidget);
    expect(find.text('티켓팅 오픈'), findsOneWidget);
    expect(find.text('5분 전'), findsOneWidget);
  });

  testWidgets('모두 읽음을 누르면 NEW가 사라지고 버튼도 숨는다', (tester) async {
    final service = _FakeNotificationsService([
      _item(id: '1', title: '알림 하나'),
      _item(id: '2', title: '알림 둘'),
    ]);
    await _openOverlay(tester, service);
    expect(find.text('NEW'), findsNWidgets(2));

    await tester.tap(find.text('모두 읽음'));
    await tester.pumpAndSettle();

    expect(service.markAllReadCalls, 1);
    expect(find.text('NEW'), findsNothing);
    expect(find.text('모두 읽음'), findsNothing);
  });

  testWidgets('티켓 알림을 누르면 닫히고 다이어리의 그 티켓으로 이동한다', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    TabNavCoordinator.resetForTest();
    final nav = TabNavCoordinator.init(
      navigatorKey: navigatorKey,
      routeBuilder: (from, to) => MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: Text('탭 이동: ${to.name}')),
      ),
      initialTab: DiaryTab.settings,
    );
    addTearDown(TabNavCoordinator.resetForTest);
    final service = _FakeNotificationsService([
      _item(id: '1', title: '내일 볼 공연', type: 'day_before', ticketId: 't1'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => NotificationsScreen.show(
                ctx,
                frameScale: 1.0,
                service: service,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('내일 볼 공연'));
    await tester.pumpAndSettle();

    expect(service.markReadCalls, ['1']);
    expect(nav.pendingDiaryTicketId, 't1');
    expect(find.text('탭 이동: diary'), findsOneWidget);
    expect(find.text('알림함'), findsNothing);
  });
}
