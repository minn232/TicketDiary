import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/connection.dart';
import 'package:ticketdiary/screen/meeting_card_screen.dart';
import 'package:ticketdiary/services/api_client.dart';
import 'package:ticketdiary/services/connection_service.dart';

/// 카드 요청이 항상 [statusCode]로 실패하는 페이크.
class _FailingConnectionService extends ConnectionService {
  _FailingConnectionService(this.statusCode);

  final int statusCode;
  int calls = 0;

  @override
  Future<ConnectionCard> getCard(String peerUserId) async {
    calls++;
    throw ApiException(statusCode, 'fail');
  }
}

const _peer = ConnectionPeer(userId: 'peer-1', nickname: '감자');

Future<void> _open(WidgetTester tester, ConnectionService service) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => MeetingCardScreen.show(
                ctx,
                frameScale: 1.0,
                peer: _peer,
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
  testWidgets('물이 걷히면 상대 이름과 일회용 안내가 보이고, 닫으면 사라진다', (tester) async {
    await _open(tester, _FailingConnectionService(500));

    expect(find.text('감자'), findsOneWidget);
    expect(find.text('지금만 볼 수 있어요. 닫으면 사라져요'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('감자'), findsNothing);
  });

  testWidgets('10분이 지나(410) 못 받으면 다시 맞대라고 안내, 다시 시도 없음', (tester) async {
    await _open(tester, _FailingConnectionService(410));

    expect(find.textContaining('기록을 볼 수 있는 시간이 지났어요'), findsOneWidget);
    expect(find.text('다시 시도'), findsNothing);
  });

  testWidgets('네트워크 오류면 다시 시도할 수 있다', (tester) async {
    final service = _FailingConnectionService(500);
    await _open(tester, service);

    expect(find.textContaining('기록을 불러오지 못했어요'), findsOneWidget);
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(service.calls, 2);
  });
}
