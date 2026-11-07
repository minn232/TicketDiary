import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/screen/news_screen.dart';
import 'package:ticketdiary/screen/news_detail_overlay.dart';
import 'package:ticketdiary/services/auth_service.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'support/fake_api.dart';

void main() {
  testWidgets('팔로우 소식 카드를 표시하고 상세를 열어 읽음 처리한다', (tester) async {
    mockStorage();
    final key = initNavigation();
    final api = installApi((r) {
      if (r.path == '/social/artists') {
        return {
          'artists': [
            {'artist_name': '넬'},
          ],
        };
      }
      if (r.path == '/social/feed') {
        return [
          for (var i = 0; i < 5; i++)
            {
              'id': 'feed-$i',
              'concert_id': '$i',
              'artist_name': '넬',
              'is_read': false,
              'concert': concertJson('$i'),
            },
        ];
      }
      return sessionResponse(r);
    });
    await tester.runAsync(() => AuthService.instance.ensureSession());
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const NewsScreen()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DiaryPageFrame), findsOneWidget);
    expect(find.text('공연 0'), findsWidgets);
    await tester.tap(find.text('공연 0').first);
    await tester.pumpAndSettle();
    expect(find.byType(NewsDetailOverlay), findsOneWidget);
    expect(
      api.requests.where((r) => r.path == '/social/feed/feed-0/read'),
      hasLength(1),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(NewsDetailOverlay), findsNothing);
    expect(find.byType(NewsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 12));
  });
}
