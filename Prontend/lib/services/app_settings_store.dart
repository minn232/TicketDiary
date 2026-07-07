import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 설정 탭의 토글들을 앱 전역에서 공유하는 저장소.
///
/// 예: "예상 셋리 노출 여부" 스위치는 설정 화면에서 바꾸지만, 실제로 그 값을
/// 참고해서 화면을 그리는 곳은 "공연 전" 페이지(포스트잇)이므로, 두 화면이
/// 같은 값을 보도록 [FavoritesStore]와 동일한 싱글턴 + SharedPreferences 패턴을 씁니다.
class AppSettingsStore extends ChangeNotifier {
  AppSettingsStore._();

  static final AppSettingsStore instance = AppSettingsStore._();

  static const _showExpectedSetlistPrefsKey = 'show_expected_setlist_v1';

  bool _showExpectedSetlist = true;
  bool _loaded = false;

  /// true(켜짐)면, "공연 전" 페이지의 예상 셋 리스트를 스포일러 방지로 블러 처리합니다.
  bool get showExpectedSetlist => _showExpectedSetlist;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      _showExpectedSetlist =
          prefs.getBool(_showExpectedSetlistPrefsKey) ?? true;
      notifyListeners();
    } catch (_) {
      // 로컬 저장소를 못 읽어도 기본값(true)으로 시작합니다.
    }
  }

  Future<void> setShowExpectedSetlist(bool value) async {
    _showExpectedSetlist = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_showExpectedSetlistPrefsKey, value);
    } catch (_) {}
  }
}
