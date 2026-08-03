import 'package:shared_preferences/shared_preferences.dart';

/// "공연 후" 티켓의 입장 티켓 조각을 뜯었는지 여부를 기기에 저장합니다.
///
/// [TicketData.tornRevealed]는 메모리에만 있어서 앱을 껐다 켜면 초기화되던
/// 것을, 티켓 id별로 shared_preferences에 남겨 앱을 재실행해도 뜯긴 상태가
/// 그대로 이어지게 합니다. 게스트/카카오 어느 쪽이든(티켓 데이터 자체가
/// 서버에 있든 로컬에 있든) 상관없이, "이 기기에서 이 티켓을 뜯어봤다"는
/// 순전히 UI 상호작용 기록이라 기기 로컬 저장만으로 충분합니다.
class TornTicketStore {
  TornTicketStore._();

  static final TornTicketStore instance = TornTicketStore._();

  static const _key = 'torn_ticket_ids';

  Set<String> _cache = {};
  bool _loaded = false;

  /// 처음 한 번만 shared_preferences에서 불러와 메모리에 캐시합니다.
  /// [isTorn]은 동기 호출이라, 이 로딩이 끝난 뒤에 값을 물어봐야 정확합니다.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    _cache = (prefs.getStringList(_key) ?? const []).toSet();
  }

  bool isTorn(String ticketId) => _cache.contains(ticketId);

  Future<void> markTorn(String ticketId) async {
    if (!_cache.add(ticketId)) return; // 이미 기록돼 있으면 다시 쓸 필요 없음
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, _cache.toList());
  }

  /// 티켓이 삭제될 때 함께 정리합니다(안 하면 지운 티켓의 id가 계속 쌓임).
  Future<void> clear(String ticketId) async {
    if (!_cache.remove(ticketId)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, _cache.toList());
  }
}
