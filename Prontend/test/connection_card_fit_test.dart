import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/connection.dart';
import 'package:ticketdiary/screen/connections_screen.dart';
import 'package:ticketdiary/services/connection_service.dart';

// 실기기 크기(노트9 세로, 탭 S8 가로)에서 카드 1장이 스크롤 없이 다 보이는지.
// CONNECTION_CARD_SCREENSHOTS=폴더 이면 화면을 PNG로 저장

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

// 실제 계정과 비슷하게 기록이 꽉 찬 카드
Map<String, dynamic> _richCard() => {
  'peer': {'user_id': 'peer', 'nickname': '손창준', 'profile_image_url': null},
  'connected_at': DateTime.now().toUtc().toIso8601String(),
  'last_met_at': null,
  'us': {
    'together_count': 3,
    'latest_together_poster_url': null,
    'compatibility': {
      'score': 74,
      'top_shared_genre': '록/밴드',
      'shared_artist_count': 5,
    },
    'common_artists': ['D.Watt', 'GLUTAMINE', 'HANATAN', 'YUURI', 'YOASOBI'],
    'my_taste': {
      'origins': ['japan'],
      'origin_mixed': false,
      'genres': ['J-pop', '록/밴드'],
    },
    'peer_taste': {
      'origins': ['domestic'],
      'origin_mixed': false,
      'genres': ['록/밴드'],
    },
  },
  'history': {
    'together_concerts': [
      _concert('YUURI ARENA LIVE 2025', -160),
      _concert('YOASOBI ASIA TOUR 2024-2025', -300),
      _concert('Live & Music Festival', -450),
    ],
    'shared_song_count': 37,
    'shared_songs': [
      {'name': '+1', 'artist': 'YUURI', 'times': 2},
      {'name': 'Ano Yume wo Nazotte', 'artist': 'YOASOBI', 'times': 2},
      {'name': 'Astronaut', 'artist': 'YUURI', 'times': 2},
    ],
    'same_concert_other_days': [
      {
        'concert': _concert('새소년 단독', -30),
        'my_date': '2026-09-12',
        'peer_date': '2026-09-13',
      },
    ],
  },
  'next': {
    'my_next': _concert('WONDERLIVET', 12),
    'peer_next': _concert('GLUTAMINE 단독 콘서트', 20),
    'together_next': null,
    'peer_next_hidden': false,
    // 2장이 가장 길어지는 경우: 관심 공연 3개 + 추천(관심 공연이 있으면 2개만 보임)
    'both_interested': [
      for (final (i, name) in ['YUURI 내한', 'HANATAN 단독', 'D.Watt 콘서트'].indexed)
        {
          'concert': _concert(name, 30 + i * 10),
          'my_status': 'ticket',
          'peer_status': 'follow',
        },
    ],
    'suggestions': [
      _concert('YOASOBI 내한', 70),
      _concert('YUURI 앙코르', 80),
      _concert('HANATAN 팬미팅', 90),
    ],
    'suggestion_basis': 'artist',
  },
};

class _Service extends ConnectionService {
  @override
  Future<ConnectionCard> getCard(String peerUserId) async =>
      ConnectionCard.fromJson(_richCard());

  @override
  Future<List<UserConnection>> listConnections() async => [];

  @override
  Future<bool> getShareNextConcert() async => true;
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final dir = Platform.environment['CONNECTION_CARD_SCREENSHOTS'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

// 카드 안 내용이 줄어든 비율 (1이면 그대로, 작을수록 넘쳐서 축소됨)
double _fitScale(WidgetTester tester, {bool last = false}) {
  final boxes = find.byType(FittedBox);
  final fitted = tester.renderObject<RenderFittedBox>(
    last ? boxes.last : boxes.first,
  );
  final child = fitted.child!.size;
  return fitted.size.height / child.height < fitted.size.width / child.width
      ? fitted.size.height / child.height
      : fitted.size.width / child.width;
}

void main() {
  for (final (name, size, frameScale) in [
    ('note9_portrait', const Size(411, 846), 1.05),
    ('tab_s8_landscape', const Size(1205, 753), 1.7),
  ]) {
    testWidgets('$name - 카드가 스크롤 없이 한 화면에', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final loader = FontLoader('NanumGalmaesgeul')
          ..addFont(rootBundle.load('assets/fonts/NanumGalmaesgeul.ttf'));
        await loader.load();
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'NanumGalmaesgeul'),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: ConnectionsScreen(
                frameScale: frameScale,
                service: _Service(),
                initialPeer: ConnectionPeer.fromJson({
                  'user_id': 'peer',
                  'nickname': '손창준',
                  'profile_image_url': null,
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 스크롤 없이 마지막 항목까지 화면 안
      final last = tester.getRect(find.textContaining('서로 다른 날 봤어요'));
      expect(last.bottom, lessThan(size.height));
      expect(
        tester.getRect(find.text('YOASOBI')).bottom,
        lessThan(size.height),
      );
      final scale = _fitScale(tester);
      // ignore: avoid_print
      print('$name fit scale = ${scale.toStringAsFixed(2)}');
      await _capture(tester, key, 'fit_$name');

      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('같이 가볼 만한 공연'), findsOneWidget);
      expect(find.text('YUURI 앙코르'), findsOneWidget);
      expect(find.text('HANATAN 팬미팅'), findsNothing); // 관심 공연이 있으면 추천은 2개
      // ignore: avoid_print
      print(
        '$name next fit scale = ${_fitScale(tester, last: true).toStringAsFixed(2)}',
      );
      await _capture(tester, key, 'fit_${name}_next');
      // 누를 때 효과음 재생의 5초 타임아웃 타이머가 끝나기를 기다림
      await tester.pump(const Duration(seconds: 6));
    });
  }
}
