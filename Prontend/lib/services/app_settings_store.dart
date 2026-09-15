import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'music_service_links.dart';
import 'notification_settings_service.dart';

/// 설정 탭의 토글들을 앱 전역에서 공유하는 저장소.
///
/// 예: "예상 셋리 노출 여부" 스위치는 설정 화면에서 바꾸지만, 실제로 그 값을
/// 참고해서 화면을 그리는 곳은 "공연 전" 페이지(포스트잇)이므로, 두 화면이
/// 같은 값을 보도록 [FavoritesStore]와 동일한 싱글턴 패턴을 씁니다.
///
// [백엔드 수정]
// show_predicted_setlist 서버에 저장.
// SharedPreferences는 네트워크 왕복 전 첫 프레임에 곧장 보여줄 캐시 용도로만 남김(source of
// truth는 서버).
/// [NotificationSettingsService]를 통해 백엔드 `show_predicted_setlist`
/// 필드와 동기화.
class AppSettingsStore extends ChangeNotifier {
  // [백엔드 수정]
  // 로그인 유저가 바뀌어도 load()가 다시 안 도는 문제 - AuthService를
  // 구독해 유저 id가 바뀌면 다시 불러옴(FavoritesStore와 동일 패턴).
  AppSettingsStore._() {
    AuthService.instance.addListener(_onAuthChanged);
  }

  static final AppSettingsStore instance = AppSettingsStore._();

  static const _showExpectedSetlistPrefsKey = 'show_expected_setlist_v1';
  // 셋리스트 곡 연결 기본 서비스 - 서버 동기화 없이 기기 로컬에만 저장(계정보다
  // 기기/앱 취향에 가까운 값이라 다른 설정들과 달리 서버 소스오브트루스 불필요).
  static const _preferredMusicServicePrefsKey = 'preferred_music_service_v1';

  final NotificationSettingsService _settingsService =
      NotificationSettingsService();

  bool _showExpectedSetlist = true;
  MusicService _preferredMusicService = MusicService.spotify;
  bool _loaded = false;

  /// 마지막으로 load()를 실행했던 유저 id.
  String? _loadedForUserId;

  void _onAuthChanged() {
    final currentUserId = AuthService.instance.userId;
    if (currentUserId == _loadedForUserId) return;
    _loadedForUserId = currentUserId;

    _loaded = false;
    unawaited(load());
  }

  /// true(켜짐)면 "공연 전" 페이지의 예상 셋 리스트를 그대로 보여주고,
  /// false(꺼짐)면 스포일러 방지로 블러 처리.
  bool get showExpectedSetlist => _showExpectedSetlist;

  /// 셋리스트 포스트잇/기사 헤더 아이콘의 기본값(설정탭에서 바꿈). 화면에서
  /// 꾹 눌러 바꾸는 임시 선택([SetlistServiceSelection])과는 별개.
  MusicService get preferredMusicService => _preferredMusicService;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    // 1) 로컬 캐시를 먼저 읽어 네트워크 응답을 기다리지 않고 즉시 반영.
    try {
      final prefs = await SharedPreferences.getInstance();
      _showExpectedSetlist =
          prefs.getBool(_showExpectedSetlistPrefsKey) ?? true;
      _preferredMusicService = MusicService.fromPrefsName(
        prefs.getString(_preferredMusicServicePrefsKey),
      );
      notifyListeners();
    } catch (_) {
      // 로컬 저장소를 못 읽어도 기본값(true/스포티파이)으로 시작합니다.
    }

    // 2) 서버 값이 진짜 source of truth이므로, 조회에 성공하면 덮어씀.
    //    실패(오프라인 등)하면 방금 읽은 로컬 캐시값.
    try {
      final settings = await _settingsService.fetch();
      _showExpectedSetlist = settings.showPredictedSetlist;
      notifyListeners();
      await _cacheLocally(_showExpectedSetlist);
    } catch (_) {}
  }

  /// 값을 바꾸고 백엔드에도 저장. 저장에 실패하면 이전 값으로 되돌리고
  /// 예외를 다시 던지므로, 호출부(설정 화면)에서 실패 안내.
  Future<void> setShowExpectedSetlist(bool value) async {
    final prev = _showExpectedSetlist;
    _showExpectedSetlist = value;
    notifyListeners();
    await _cacheLocally(value);

    try {
      await _settingsService.update(showPredictedSetlist: value);
    } catch (e) {
      _showExpectedSetlist = prev;
      notifyListeners();
      await _cacheLocally(prev);
      rethrow;
    }
  }

  Future<void> _cacheLocally(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_showExpectedSetlistPrefsKey, value);
    } catch (_) {}
  }

  /// 기기 로컬에만 저장(서버 동기화 없음 - 위 [_preferredMusicServicePrefsKey] 참고).
  Future<void> setPreferredMusicService(MusicService value) async {
    _preferredMusicService = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_preferredMusicServicePrefsKey, value.prefsName);
    } catch (_) {}
  }
}
