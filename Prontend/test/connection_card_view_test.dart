import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/connection.dart';
import 'package:ticketdiary/screen/connections_screen.dart';
import 'package:ticketdiary/services/connection_service.dart';
import 'package:ticketdiary/widgets/connection_card_view.dart';

// 공연 날짜는 한국 날짜를 UTC 자정으로 저장하는 규칙
String _utcDay(int daysFromToday) {
  final now = DateTime.now();
  final d = DateTime(now.year, now.month, now.day + daysFromToday);
  return DateTime.utc(d.year, d.month, d.day).toIso8601String();
}

Map<String, dynamic> _concert(String name, int day) => {
  'id': name,
  'name': name,
  'poster_url': null,
  'venue': '테스트홀',
  'start_date': _utcDay(day),
  'end_date': _utcDay(day),
  'attended_date': null,
  'ticketing_date': null,
};

Map<String, dynamic> _cardJson({bool withHistory = true}) => {
  'peer': {'user_id': 'peer', 'nickname': '민지', 'profile_image_url': null},
  'connected_at': DateTime.now().toUtc().toIso8601String(),
  'last_met_at': null,
  'us': {
    'together_count': withHistory ? 3 : 0,
    'latest_together_poster_url': null,
    'compatibility': {
      'score': 82,
      'top_shared_genre': '록/밴드',
      'shared_artist_count': 4,
    },
    'common_artists': ['실리카겔', '잔나비', '새소년'],
    'my_taste': {
      'origins': ['anglo'],
      'origin_mixed': false,
      'genres': ['록/밴드'],
    },
    'peer_taste': {
      'origins': ['domestic', 'japan'],
      'origin_mixed': false,
      'genres': ['인디', '록/밴드'],
    },
  },
  'history': {
    'together_concerts': withHistory
        ? [_concert('펜타포트 락 페스티벌', -60), _concert('잔나비 전국투어', -120)]
        : [],
    'shared_song_count': withHistory ? 12 : 0,
    'shared_songs': withHistory
        ? [
            {'name': '주저하는 연인들을 위해', 'artist': '잔나비', 'times': 4},
            {'name': 'NO PAIN', 'artist': '실리카겔', 'times': 3},
          ]
        : [],
    'same_concert_other_days': withHistory
        ? [
            {
              'concert': _concert('새소년 단독', -30),
              'my_date': '2026-09-12',
              'peer_date': '2026-09-13',
            },
          ]
        : [],
  },
  'next': {
    'my_next': _concert('실리카겔 단독', 12),
    'peer_next': null,
    'together_next': null,
    'peer_next_hidden': true,
    'both_interested': [
      {
        'concert': _concert('잔나비 연말콘', 40),
        'my_status': 'ticket',
        'peer_status': 'follow',
      },
    ],
    'suggestions': [],
  },
};

Future<void> _pump(
  WidgetTester tester,
  ConnectionCard card,
  GlobalKey boundary,
) async {
  tester.view.physicalSize = const Size(780, 1560);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(() async {
    final loader = FontLoader('NanumGalmaesgeul')
      ..addFont(rootBundle.load('assets/fonts/NanumGalmaesgeul.ttf'));
    await loader.load();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'NanumGalmaesgeul'),
      home: Scaffold(
        backgroundColor: const Color(0xFFF4F1E1),
        body: RepaintBoundary(
          key: boundary,
          child: ConnectionCardView(card: card),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// CONNECTION_CARD_SCREENSHOTS=1이면 장마다 PNG로 저장 (레이아웃 눈으로 확인용)
Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  final dir = Platform.environment['CONNECTION_CARD_SCREENSHOTS'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final image =
        await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  test('취향 라벨 - 국적만/장르만/여러 나라', () {
    Taste taste(
      List<String> origins,
      List<String> genres, {
      bool mixed = false,
    }) => Taste(origins: origins, originMixed: mixed, genres: genres);
    expect(taste(['anglo'], []).label, '영미권 음악');
    expect(taste([], ['힙합']).label, '힙합');
    expect(taste([], ['힙합'], mixed: true).label, '여러 나라 힙합');
    expect(taste(['anglo', 'japan'], ['팝']).label, '영미권과 일본 팝');
  });

  testWidgets('1장에 취향·궁합과 함께한 기록, 2장에 다음 공연', (tester) async {
    final boundary = GlobalKey();
    await _pump(tester, ConnectionCard.fromJson(_cardJson()), boundary);

    expect(find.text('민지님과 나'), findsOneWidget);
    expect(find.text('취향 궁합 82%'), findsOneWidget);
    expect(find.text('영미권 록/밴드'), findsOneWidget);
    expect(find.text('국내와 일본 인디, 록/밴드'), findsOneWidget);
    expect(find.text('같이 간 공연 2회'), findsOneWidget);
    // 같이 간 공연이 있어도 공통 아티스트를 보여줌
    expect(find.text('둘 다 좋아하는 아티스트'), findsOneWidget);
    await _capture(tester, boundary, 'page1');
    await tester.dragUntilVisible(
      find.text('둘 다 라이브로 들은 곡 12곡'),
      find.byType(SingleChildScrollView).first,
      const Offset(0, -200),
    );
    await _capture(tester, boundary, 'page1_scrolled');

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('민지님의 다음 공연은 비공개예요'), findsOneWidget);
    expect(find.text('둘 다 찜하거나 예매한 공연'), findsOneWidget);
    await _capture(tester, boundary, 'page2');
  });

  testWidgets('같이 간 기록이 없으면 취향과 공통 아티스트만', (tester) async {
    final boundary = GlobalKey();
    await _pump(
      tester,
      ConnectionCard.fromJson(_cardJson(withHistory: false)),
      boundary,
    );

    expect(find.text('실리카겔'), findsOneWidget);
    expect(find.textContaining('같이 간 공연'), findsNothing);
    await _capture(tester, boundary, 'page1_no_history');

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('다음에 같이'), findsOneWidget);
  });

  connectionsScreenTests();
}

class _FakeConnectionService extends ConnectionService {
  @override
  Future<List<UserConnection>> listConnections() async => [
    UserConnection.fromJson({
      'connection_id': 'c1',
      'peer': {'user_id': 'peer', 'nickname': '민지', 'profile_image_url': null},
      'connected_at': DateTime.now().toUtc().toIso8601String(),
      'last_met_at': null,
    }),
  ];

  @override
  Future<ConnectionCard> getCard(String peerUserId) async =>
      ConnectionCard.fromJson(_cardJson());

  @override
  Future<bool> getShareNextConcert() async => true;
}

void connectionsScreenTests() {
  testWidgets('다음 공연이 없는 쪽은 없다고 표시', (tester) async {
    final json = _cardJson();
    (json['next'] as Map<String, dynamic>)
      ..['peer_next'] = null
      ..['peer_next_hidden'] = false;
    final boundary = GlobalKey();
    await _pump(tester, ConnectionCard.fromJson(json), boundary);
    for (var i = 0; i < 2; i++) {
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
    }
    await _capture(tester, boundary, 'page3_empty_peer');

    expect(find.text('각자의 다음 공연'), findsOneWidget);
    expect(find.text('민지님은 아직 예정된 공연이 없어요'), findsOneWidget);
  });

  testWidgets('연결 목록에서 친구를 누르면 카드가 열림', (tester) async {
    final boundary = GlobalKey();
    tester.view.physicalSize = const Size(780, 1560);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundary,
          child: Builder(
            builder: (context) => Scaffold(
              body: ConnectionsScreen(
                frameScale: 1,
                service: _FakeConnectionService(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('연결된 친구'), findsOneWidget);
    expect(find.text('내 다음 공연 보여주기'), findsOneWidget);
    await _capture(tester, boundary, 'list');

    await tester.tap(find.text('민지'));
    await tester.pumpAndSettle();
    expect(find.text('민지님과 나'), findsOneWidget);
    await _capture(tester, boundary, 'list_open_card');
    // 누를 때 효과음 재생의 5초 타임아웃 타이머가 끝나기를 기다림
    await tester.pump(const Duration(seconds: 6));
  });
}
