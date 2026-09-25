import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/setlist.dart';
import 'package:ticketdiary/widgets/artist_anchor_sheet.dart';

const _kimA = ArtistCandidate(
  itunesArtistId: '1',
  artistName: '김현정',
  genre: 'K-Pop',
  topSongs: ['그녀와의 이별', '멍'],
);
const _kimB = ArtistCandidate(
  itunesArtistId: '2',
  artistName: '김현정',
  genre: 'Classical',
  topSongs: ['謝肉祭'],
);
const _songCandidate = ArtistAnchorCandidate(
  itunesArtistId: '3',
  artistName: '김현정',
  trackName: '혼자한 사랑',
  albumName: '앨범',
);

Future<void> _openSheet(
  WidgetTester tester, {
  required Future<List<ArtistCandidate>> Function() onSearchArtists,
  Future<List<ArtistAnchorCandidate>> Function(String)? onSearchSongs,
  required Future<void> Function(String) onPick,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => ArtistAnchorSheet.show(
                ctx,
                artist: '김현정',
                onSearchArtists: onSearchArtists,
                onSearchSongs: onSearchSongs ?? (_) async => const [],
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
  testWidgets('열리면 아티스트 후보를 보여주고 고르면 그 아티스트로 확정된다', (tester) async {
    String? picked;
    await _openSheet(
      tester,
      onSearchArtists: () async => const [_kimA, _kimB],
      onPick: (id) async => picked = id,
    );

    expect(find.text('어느 김현정인가요?'), findsOneWidget);
    expect(find.text('김현정 · K-Pop'), findsOneWidget);
    expect(find.text('그녀와의 이별 · 멍'), findsOneWidget);
    expect(find.text('김현정 · Classical'), findsOneWidget);

    await tester.tap(find.text('김현정 · Classical'));
    await tester.pumpAndSettle();

    expect(picked, '2');
    expect(find.byType(ArtistAnchorSheet), findsNothing);
  });

  testWidgets('여기 없어요를 누르면 곡 제목으로 찾아 고를 수 있다', (tester) async {
    String? searched;
    String? picked;
    await _openSheet(
      tester,
      onSearchArtists: () async => const [_kimA],
      onSearchSongs: (song) async {
        searched = song;
        return const [_songCandidate];
      },
      onPick: (id) async => picked = id,
    );

    await tester.tap(find.text('여기 없어요 · 곡 제목으로 찾기'));
    await tester.pumpAndSettle();
    expect(find.text('김현정의 노래를 하나 알려주세요'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '혼자한 사랑');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(searched, '혼자한 사랑');
    expect(find.text('김현정 · 앨범'), findsOneWidget);

    await tester.tap(find.text('혼자한 사랑').last);
    await tester.pumpAndSettle();
    expect(picked, '3');
  });

  testWidgets('아티스트 후보가 없으면 바로 곡 제목 검색으로 시작한다', (tester) async {
    await _openSheet(
      tester,
      onSearchArtists: () async => const [],
      onPick: (_) async {},
    );

    expect(find.text('김현정의 노래를 하나 알려주세요'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('확정에 실패하면 시트를 닫지 않고 오류를 보여준다', (tester) async {
    await _openSheet(
      tester,
      onSearchArtists: () async => const [_kimA],
      onPick: (_) async => throw Exception('fail'),
    );

    await tester.tap(find.text('김현정 · K-Pop'));
    await tester.pumpAndSettle();

    expect(find.byType(ArtistAnchorSheet), findsOneWidget);
    expect(find.text('대표곡을 불러오지 못했어요. 다른 후보로 다시 시도해주세요.'), findsOneWidget);
  });

  test('모델 파싱 - SongEntry.source, 빈 예상 셋리(id 없음), 아티스트 후보', () {
    final song = SongEntry.fromJson({
      'name': '곡',
      'encore': false,
      'source': 'representative',
    });
    expect(song.isRepresentative, isTrue);
    expect(song.toJson()['source'], 'representative');
    expect(const SongEntry(name: '곡').isRepresentative, isFalse);

    final empty = PreSetlistResponse.fromJson({
      'id': null,
      'concert_id': 'c1',
      'setlistfm_id': null,
      'songs': <dynamic>[],
      'is_user_edited': false,
      'edited_user_nickname': null,
      'artist_names': ['잔나비'],
    });
    expect(empty.id, isNull);
    expect(empty.artistNames, ['잔나비']);

    final candidate = ArtistCandidate.fromJson({
      'itunes_artist_id': '913424316',
      'artist_name': '잔나비',
      'genre': 'K-Pop',
      'top_songs': ['주저하는 연인들을 위해'],
      'artwork_url': null,
    });
    expect(candidate.topSongs, ['주저하는 연인들을 위해']);
  });
}
