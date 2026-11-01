import 'package:shared_preferences/shared_preferences.dart';

// [백엔드 수정]
// 배송일 강조 연출을 이미 보여준 티켓 id. 앱 메모리에만 두면 앱을 다시 켤 때마다
// 같은 티켓을 또 강조하므로 기기 로컬에 저장(서버 동기화 없음).
class DeliveryAttentionStore {
  DeliveryAttentionStore._();
  static final instance = DeliveryAttentionStore._();

  static const _prefsKey = 'delivery_attention_played_ids_v1';

  final Set<String> _playedIds = {};
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _playedIds.addAll(prefs.getStringList(_prefsKey) ?? const []);
    } catch (_) {}
  }

  bool hasPlayed(String? ticketId) => _playedIds.contains(ticketId);

  /// [activeIds](지금 배송 전인 티켓)에 없는 id는 함께 지워 목록이 계속 쌓이지 않게 함.
  Future<void> markPlayed(String ticketId, Iterable<String> activeIds) async {
    _playedIds
      ..add(ticketId)
      ..retainAll({...activeIds, ticketId});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, _playedIds.toList());
    } catch (_) {}
  }
}
