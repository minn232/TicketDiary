import 'package:flutter/foundation.dart';
import '../models/news_model.dart';
import 'favorites_store.dart';
import 'social_service.dart';

/// 소식탭과 결산 캘린더가 사용하는 동일한 카드 목록.
class NewsListService {
  static final updates = ValueNotifier<List<NewsModel>?>(null);
  static Future<List<NewsModel>>? _pending;
  Future<List<NewsModel>> load() {
    return _pending ??= _fetch()
        .then((items) {
          updates.value = items;
          return items;
        })
        .whenComplete(() => _pending = null);
  }

  final _socialService = SocialService();
  Future<List<NewsModel>> _fetch() async {
    // 백엔드 피드는 서버에 저장된 팔로우 목록 기준으로 생성되므로,
    // 로컬 찜 아티스트 목록을 먼저 서버에 동기화한 뒤 피드를 조회합니다.
    // [백엔드 수정] syncFromServer() 호출 추가.
    await FavoritesStore.instance.load();
    await FavoritesStore.instance.syncFromServer();
    final artistNames = FavoritesStore.instance.favoriteArtists
        .map((a) => a.name)
        .toList();
    // [백엔드 수정]
    // syncArtistFollows()가 반환하는 최신 목록을 재사용(getArtistFollowEntries()
    // 중복 호출 제거), 동기화 실패 시에만 아래에서 별도로 다시 조회함.
    List<Map<String, dynamic>>? entries;
    try {
      entries = await _socialService.syncArtistFollows(artistNames);
    } catch (_) {
      // 동기화에 실패해도(네트워크 순단 등) 기존 서버 팔로우 목록 기준의
      // 피드는 조회할 수 있으므로 계속 진행합니다.
    }

    final feed = await _socialService.getNewsFeed();

    // 백엔드는 한 번 생성된 소식을 아티스트 언팔로우 후에도 지우지 않고
    // 그대로 돌려주므로(GET /social/feed가 팔로우 상태와 무관하게 전체
    // 반환), 지금 실제로 팔로우 중인 아티스트의 소식만 화면에 남깁니다.
    List<NewsModel> filteredFeed;
    try {
      entries ??= await _socialService.getArtistFollowEntries();
      final currentFollows = {
        for (final e in entries)
          if ((e['artist_name'] as String?)?.isNotEmpty ?? false)
            e['artist_name'] as String,
      };
      filteredFeed = feed
          .where((item) => currentFollows.contains(item.artist))
          .toList();
    } catch (_) {
      // 팔로우 목록 조회에 실패하면 필터링 없이 원본 그대로 보여줍니다.
      filteredFeed = feed;
    }

    // 찜한 공연은 아티스트 매칭을 거치지 않고 그대로 카드로 보여줍니다.
    // D-day(공연 시작일) 당일부터는 카드에서 제외(찜 상태는 유지).
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final favoritedConcertCards = FavoritesStore.instance.favoriteConcerts
        .where((c) {
          final start = c.startDate;
          if (start == null) return true;
          return DateTime(
            start.year,
            start.month,
            start.day,
          ).isAfter(todayDate);
        })
        .map(NewsModel.fromFavoritedConcert)
        .toList();

    // 이미 찜한 공연 카드로 나온 concertId는 아티스트 소식 카드에서 제외합니다
    // (공연 찜 + 그 공연 아티스트 팔로우가 겹치면 같은 공연이 카드 2장으로
    // 중복 노출되던 버그).
    final favoritedConcertIds = favoritedConcertCards
        .map((c) => c.concertId)
        .whereType<String>()
        .toSet();
    filteredFeed = filteredFeed
        .where(
          (item) =>
              item.concertId == null ||
              !favoritedConcertIds.contains(item.concertId),
        )
        .toList();

    final combined = [...favoritedConcertCards, ...filteredFeed];
    // 공연이 가까운 순(D-day 오름차순)으로 정렬합니다 — 그리드는 왼쪽
    // 위부터 오른쪽 아래로 채워지므로, 리스트 순서가 곧 화면 배치 순서가
    // 됩니다. 날짜 정보가 없는 카드는 맨 뒤로 밀립니다.
    combined.sort((a, b) {
      final da = a.concertDate;
      final db = b.concertDate;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    });
    return combined;
  }
}
