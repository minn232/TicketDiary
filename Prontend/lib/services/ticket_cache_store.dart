import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/ticket_response.dart';

// [백엔드 수정]
// 다이어리 탭 로컬 캐시 신규 - `GET /tickets` 원본을 저장해두고, 서버 조회가
// 실패하면(오프라인 등) 대신 읽기 전용으로 보여줍니다.
class TicketCacheStore {
  TicketCacheStore._();
  static final TicketCacheStore instance = TicketCacheStore._();

  static const _key = 'diary_ticket_cache_v1';
  static const _userKey = 'diary_ticket_cache_user_id_v1';

  /// 캐시를 저장했을 때의 로그인 유저 id와 지금 유저 id가 다르면(로그아웃/
  /// 계정 전환), 다른 사람의 티켓을 잘못 보여주지 않도록 null을 돌려줍니다.
  Future<List<TicketWithConcert>?> load({required String? userId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_userKey) != (userId ?? '')) return null;
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => TicketWithConcert.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // 손상된 캐시는 없는 것과 동일하게 처리합니다.
      return null;
    }
  }

  Future<void> save(
    List<TicketWithConcert> tickets, {
    required String? userId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(tickets.map((e) => e.toJson()).toList());
      await prefs.setString(_key, raw);
      await prefs.setString(_userKey, userId ?? '');
    } catch (_) {
      // 저장 실패는 다음에 서버에서 다시 불러오면 되므로 무시합니다.
    }
  }
}
