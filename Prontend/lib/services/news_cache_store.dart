import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/news_model.dart';

/// 소식 탭 데이터(찜한 공연 + 팔로우 피드, 화면에 보여줄 형태로 이미 가공된
/// 것)를 기기 로컬(SharedPreferences)에 캐시합니다.
///
/// [NewsScreen]은 이 캐시가 있으면 먼저 즉시 보여주고, 그 뒤 조용히
/// 최신 데이터를 다시 조회해 캐시와 화면을 함께 갱신합니다("stale while
/// revalidate") — 데이터 양이 많아질수록 매번 네트워크 응답을 기다리는
/// 대신, 최소한 예전 데이터라도 즉시 보여줘서 체감 로딩 시간을 줄입니다.
class NewsCacheStore {
  NewsCacheStore._();
  static final NewsCacheStore instance = NewsCacheStore._();

  static const _key = 'news_feed_cache_v1';
  static const _revisionKey = 'news_feed_cache_favorites_revision_v1';

  /// [favoritesRevision]은 캐시를 저장하던 시점의 [FavoritesStore.revision]
  /// 입니다. 지금 값과 다르면(=찜 목록을 바꾼 뒤 첫 방문) 이 캐시는 옛
  /// 찜 목록 기준이라 못 미더우므로 null을 돌려줘서 항상 최신 데이터를
  /// 다시 불러오게 합니다 — "찜을 새로 고쳤는데 소식 탭엔 예전 목록이
  /// 보이다가 다른 탭을 갔다 와야 반영된다"는 문제의 원인이었습니다.
  Future<List<NewsModel>?> load({required int favoritesRevision}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(_revisionKey) != favoritesRevision) return null;
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => NewsModel.fromCacheJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // 캐시가 손상됐거나(포맷 변경 등) 읽기에 실패하면 캐시가 없는 것과
      // 동일하게 처리합니다 — 어차피 뒤이어 네트워크에서 다시 불러옵니다.
      return null;
    }
  }

  Future<void> save(List<NewsModel> items, {required int favoritesRevision}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(items.map((e) => e.toJson()).toList());
      await prefs.setString(_key, raw);
      await prefs.setInt(_revisionKey, favoritesRevision);
    } catch (_) {
      // 저장 실패(용량 부족 등)는 다음 방문 때 캐시 없이 다시 불러오는
      // 것으로 충분하므로 조용히 무시합니다.
    }
  }
}
