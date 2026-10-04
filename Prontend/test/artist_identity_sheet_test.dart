import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/setlist.dart';
import 'package:ticketdiary/widgets/artist_identity_sheet.dart';

const _current = IdentityCandidate(
  canonicalId: 'c1',
  mbid: 'm1',
  name: '이재경',
  country: 'KR',
  type: 'Person',
  isCurrent: true,
);
const _other = IdentityCandidate(
  mbid: 'm2',
  name: '이재경',
  country: 'KR',
  type: 'Person',
  beginYear: '2005',
  disambiguation: 'NELL guitarist',
  topSongs: ['기억을 걷는 시간', 'Stay'],
);

Future<void> _openSheet(
  WidgetTester tester, {
  required Future<void> Function(IdentityCandidate?) onPick,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => ArtistIdentitySheet.show(
                ctx,
                artist: '이재경',
                onLoad: () async => const IdentityCandidatesResponse(
                  candidates: [_other, _current],
                ),
                onPick: onPick,
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
  testWidgets('후보를 동명이인 구분 정보와 함께 보여주고 고르면 그 후보로 바꾼다', (tester) async {
    final picked = <IdentityCandidate?>[];
    await _openSheet(tester, onPick: (c) async => picked.add(c));

    expect(find.text('현재 아티스트'), findsOneWidget);
    expect(find.text('한국 · 솔로 · 2005년~ · NELL guitarist'), findsOneWidget);
    expect(find.text('♪ 기억을 걷는 시간 · Stay'), findsOneWidget);

    await tester.tap(find.text('한국 · 솔로 · 2005년~ · NELL guitarist'));
    await tester.pumpAndSettle();

    expect(picked, [_other]);
    expect(find.byType(ArtistIdentitySheet), findsNothing);
  });

  testWidgets('현재 아티스트가 목록 맨 위에 온다', (tester) async {
    await _openSheet(tester, onPick: (_) async {});

    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles.first.trailing, isNotNull);
    expect(tiles.last.trailing, isNull);
  });

  testWidgets('현재 아티스트를 고르면 바꾸지 않고 닫힌다', (tester) async {
    final picked = <IdentityCandidate?>[];
    await _openSheet(tester, onPick: (c) async => picked.add(c));

    await tester.tap(find.text('현재 아티스트'));
    await tester.pumpAndSettle();

    expect(picked, isEmpty);
    expect(find.byType(ArtistIdentitySheet), findsNothing);
  });

  testWidgets('"아티스트가 아니에요"는 null로 넘긴다', (tester) async {
    final picked = <IdentityCandidate?>[];
    await _openSheet(tester, onPick: (c) async => picked.add(c));

    await tester.tap(find.text('아티스트가 아니에요'));
    await tester.pumpAndSettle();

    expect(picked, [null]);
  });

  testWidgets('실패하면 시트에 남아 오류를 보여준다', (tester) async {
    await _openSheet(tester, onPick: (_) async => throw Exception('x'));

    await tester.tap(find.text('한국 · 솔로 · 2005년~ · NELL guitarist'));
    await tester.pumpAndSettle();

    expect(find.byType(ArtistIdentitySheet), findsOneWidget);
    expect(find.text('바꾸지 못했어요. 잠시 후 다시 시도해주세요.'), findsOneWidget);
  });

  testWidgets('"목록에 없어요"는 곡 제목 검색으로 넘어가라고 true를 돌려준다', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await ArtistIdentitySheet.show(
                  ctx,
                  artist: '이재경',
                  onLoad: () async => const IdentityCandidatesResponse(),
                  onPick: (_) async {},
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('같은 이름의 아티스트를 찾지 못했어요.'), findsOneWidget);
    await tester.tap(find.text('목록에 없어요 · 노래 제목으로 찾기'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });

  testWidgets('곡 제목 검색을 끄면 "목록에 없어요"가 없다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => ArtistIdentitySheet.show(
                ctx,
                artist: '이재경',
                allowSongSearch: false,
                onLoad: () async => const IdentityCandidatesResponse(
                  candidates: [_other, _current],
                ),
                onPick: (_) async {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('목록에 없어요 · 노래 제목으로 찾기'), findsNothing);
    expect(find.text('아티스트가 아니에요'), findsOneWidget);
  });
}
