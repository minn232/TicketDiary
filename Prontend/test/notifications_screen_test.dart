import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/notification_model.dart';
import 'package:ticketdiary/screen/notifications_screen.dart';
import 'package:ticketdiary/services/notifications_service.dart';

/// 실제 네트워크 없이 목록/읽음/삭제 호출을 흉내내는 페이크. list()가
/// 반환하는 목록은 내부 상태를 그대로 반영해, 삭제 후 다시 열어도
/// 일관되게 동작합니다.
class _FakeNotificationsService extends NotificationsService {
  _FakeNotificationsService(List<NotificationModel> initial)
      : _items = List.of(initial);

  final List<NotificationModel> _items;
  final List<String> markReadCalls = [];
  final List<String> deleteCalls = [];

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
}) {
  return NotificationModel(
    id: id,
    type: 'general',
    title: title,
    body: '$title 본문입니다.',
    isRead: isRead,
    scheduledAt: DateTime(2026, 9, 7, 10, 30),
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
}
