import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/connection.dart';
import 'package:ticketdiary/screen/connections_screen.dart';
import 'package:ticketdiary/services/connection_service.dart';
import 'package:ticketdiary/widgets/sheet_grab_handle.dart';

/// 네트워크 없이 빈 친구 목록을 돌려주는 페이크.
class _FakeConnectionService extends ConnectionService {
  @override
  Future<List<UserConnection>> listConnections() async => [];

  @override
  Future<bool> getShareNextConcert() async => false;
}

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => ConnectionsScreen.show(
                ctx,
                frameScale: 1.0,
                service: _FakeConnectionService(),
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
  testWidgets('친구창에도 손잡이 막대가 있다', (tester) async {
    await _open(tester);
    expect(find.byType(SheetGrabHandle), findsOneWidget);
  });

  testWidgets('제목줄을 아래로 끌면 닫히고, 조금만 끌면 제자리로 돌아온다', (tester) async {
    await _open(tester);

    await tester.drag(find.text('연결된 친구'), const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(find.text('연결된 친구'), findsOneWidget);

    await tester.fling(find.text('연결된 친구'), const Offset(0, 300), 1500);
    await tester.pumpAndSettle();
    expect(find.text('연결된 친구'), findsNothing);
  });
}
