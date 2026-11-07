import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/models/artist_model.dart';
import 'package:ticketdiary/widgets/news_card_reason.dart';

void main() {
  NewsModel card() => NewsModel(
    artist: '찜한 공연',
    concert: '페스티벌',
    imageUrl: '',
    description: '',
    isFavoritedConcert: true,
    lineup: ['A', 'B', 'C'],
  );
  test('전체 출연진 중 찜한 아티스트만 중복 없이 매칭하고 캐시에 보존한다', () {
    final item = card()
      ..matchFavorites(const [
        ArtistModel(name: 'A', profileImageUrl: 'a'),
        ArtistModel(name: 'B', profileImageUrl: 'b'),
        ArtistModel(name: 'a', profileImageUrl: 'duplicate'),
        ArtistModel(name: 'D', profileImageUrl: 'd'),
      ]);
    expect(item.matchedArtists.map((a) => a.name), ['A', 'B']);
    final cached = NewsModel.fromCacheJson(item.toJson());
    expect(cached.matchedArtists.map((a) => a.profileImageUrl), ['a', 'b']);
  });
  testWidgets('공연 찜 문구보다 프로필을 우선하고 이름을 툴팁으로 제공한다', (tester) async {
    final item = card();
    Future<void> show() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 110, child: NewsCardReason(data: item)),
        ),
      ),
    );
    await show();
    expect(find.text('♥'), findsOneWidget);
    item.matchFavorites(const [
      ArtistModel(name: 'A', profileImageUrl: ''),
      ArtistModel(name: 'B', profileImageUrl: ''),
    ]);
    await show();
    expect(find.text('찜한 공연'), findsNothing);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.byTooltip('찜한 아티스트: A, B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('많은 프로필은 생략하지 않고 가로 스크롤한다', (tester) async {
    final item = card();
    item.matchedArtists = List.generate(
      12,
      (i) => ArtistModel(name: 'artist$i', profileImageUrl: ''),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 110,
            height: 20,
            child: NewsCardReason(data: item),
          ),
        ),
      ),
    );
    // 프로필이 영역을 넘으면 수동 스크롤 없이 자동 마키 애니메이션을 사용한다.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.byKey(const ValueKey('news-artist-artist11')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
