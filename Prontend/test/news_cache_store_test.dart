import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/models/concert_model.dart';
import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/services/news_cache_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('처음엔 캐시가 없다', () async {
    final loaded = await NewsCacheStore.instance.load(favoritesRevision: 0);
    expect(loaded, isNull);
  });

  test('저장한 뒤 같은 revision으로 불러오면 내용이 그대로 복원된다', () async {
    final items = [
      NewsModel(
        id: 'feed-1',
        concertId: 'concert-1',
        isRead: false,
        artist: '아이유',
        concert: '테스트 공연',
        imageUrl: 'https://example.com/p.png',
        description: '새 공연이 등록됐어요!',
        contentTop: '공연 기간  2026.01.01',
        contentBottom: '예매 일정은 예매처에서 확인해주세요.',
        articleImageUrl: 'https://example.com/p.png',
        venue: '테스트홀',
      ),
      NewsModel.fromFavoritedConcert(
        const ConcertModel(name: '찜한 테스트 공연', posterImageUrl: ''),
      ),
    ];

    await NewsCacheStore.instance.save(items, favoritesRevision: 3);
    final loaded = await NewsCacheStore.instance.load(favoritesRevision: 3);

    expect(loaded, isNotNull);
    expect(loaded!.length, 2);
    expect(loaded[0].id, 'feed-1');
    expect(loaded[0].artist, '아이유');
    expect(loaded[0].venue, '테스트홀');
    expect(loaded[0].isRead, isFalse);
    expect(loaded[1].artist, '찜한 공연');
  });

  test('저장 당시와 revision이 다르면(찜 목록이 바뀌었으면) 캐시를 못 미더운 것으로 보고 null을 돌려준다', () async {
    final items = [
      NewsModel(
        artist: '아이유',
        concert: '테스트 공연',
        imageUrl: '',
        description: '',
      ),
    ];

    await NewsCacheStore.instance.save(items, favoritesRevision: 1);
    // 찜 목록을 바꾼 뒤(revision이 2로 늘어난 상황) 소식 탭에 들어온 경우.
    final loaded = await NewsCacheStore.instance.load(favoritesRevision: 2);

    expect(loaded, isNull);
  });
}
