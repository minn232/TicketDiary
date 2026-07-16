import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/artist_model.dart';
import '../models/concert_model.dart';
import '../models/ticket_scan.dart';
import 'api_client.dart';
import 'social_service.dart';

/// 사용자가 "찜"한 아티스트/공연을 보관하는 전역 저장소.
///
/// 설정 > 선호 아티스트 / 찜 공연 화면에서 찜을 토글하면 여기에 반영되고,
/// 소식 탭은 이 목록을 기준으로 어떤 아티스트/공연의 소식만 불러올지 결정합니다.
///
/// 저장 구조:
/// - 기기 로컬(SharedPreferences): 이름/이미지까지 포함한 전체 표시용 데이터.
/// - 서버(`/social/artists`, `/social/concerts`): 찜 변경 때마다 전체 목록으로
///   교체 반영(해제도 서버에서 지워짐). 서버가 소식 피드를 만들 때 이 목록을
///   사용합니다. [syncFromServer]로 다른 기기에서 등록한 찜도 로컬로 병합합니다.
class FavoritesStore extends ChangeNotifier {
  FavoritesStore._();

  static final FavoritesStore instance = FavoritesStore._();

  static const _artistsPrefsKey = 'favorite_artists_v1';
  static const _concertsPrefsKey = 'favorite_concerts_v1';

  final SocialService _social = SocialService();

  final Map<String, ArtistModel> _artists = {};
  final Map<String, ConcertModel> _concerts = {};

  bool _loaded = false;
  bool _serverSynced = false;

  List<ArtistModel> get favoriteArtists => _artists.values.toList();
  List<ConcertModel> get favoriteConcerts => _concerts.values.toList();

  bool isArtistFavorited(String name) => _artists.containsKey(name);
  bool isConcertFavorited(String name) => _concerts.containsKey(name);

  /// 앱 로컬에 저장된 찜 목록을 불러옵니다. 여러 번 호출해도 한 번만 실제로 로드합니다.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      _restoreArtists(prefs.getString(_artistsPrefsKey));
      _restoreConcerts(prefs.getString(_concertsPrefsKey));
      notifyListeners();
    } catch (_) {
      // 로컬 저장소를 못 읽어도 빈 상태로 시작합니다.
    }
  }

  /// 서버에 저장된 찜 목록을 로컬로 병합합니다(다른 기기에서 등록한 찜 반영).
  ///
  /// - 아티스트: 서버에만 있는 이름을 추가(이미지는 없음).
  /// - 공연: 서버에만 있는 항목은 `kopis_concert_id`가 있으면
  ///   `GET /concerts/{kopis_id}`로 이름/포스터를 되찾아 추가하고, 없으면
  ///   표시할 방법이 없어 건너뜁니다.
  ///
  /// 실패해도(비로그인/네트워크) 로컬 목록만으로 동작합니다.
  Future<void> syncFromServer() async {
    if (_serverSynced) return;
    _serverSynced = true;

    var changed = false;
    try {
      final entries = await _social.getArtistFollowEntries();
      for (final e in entries) {
        final name = (e['artist_name'] as String?)?.trim() ?? '';
        if (name.isNotEmpty && !_artists.containsKey(name)) {
          _artists[name] = ArtistModel(name: name, profileImageUrl: '');
          changed = true;
        }
      }
    } catch (_) {
      _serverSynced = false;
    }

    try {
      final entries = await _social.getConcertFollowEntries();
      final localIds = {
        for (final c in _concerts.values)
          if (c.id.isNotEmpty) c.id,
      };
      for (final e in entries) {
        final concertId = e['concert_id'] as String? ?? '';
        final kopisId = e['kopis_concert_id'] as String?;
        if (concertId.isEmpty || localIds.contains(concertId)) continue;
        if (kopisId == null || kopisId.isEmpty) continue;
        try {
          final json = await _client.get('/concerts/$kopisId');
          final detail = ConcertResponse.fromJson(json);
          if (!_concerts.containsKey(detail.name)) {
            _concerts[detail.name] = ConcertModel(
              name: detail.name,
              posterImageUrl: detail.posterUrl ?? '',
              id: detail.id,
              kopisId: detail.kopisId,
            );
            changed = true;
          }
        } catch (_) {
          // 개별 공연 복원 실패는 건너뜁니다.
        }
      }
    } catch (_) {
      _serverSynced = false;
    }

    if (changed) {
      notifyListeners();
      await _persistArtists();
      await _persistConcerts();
    }
  }

  ApiClient get _client => ApiClient.instance;

  void _restoreArtists(String? raw) {
    if (raw == null || raw.isEmpty) return;
    final list = jsonDecode(raw) as List<dynamic>;
    for (final entry in list) {
      final map = entry as Map<String, dynamic>;
      final artist = ArtistModel(
        name: map['name'] as String? ?? '',
        profileImageUrl: map['profileImageUrl'] as String? ?? '',
      );
      if (artist.name.isNotEmpty) {
        _artists[artist.name] = artist;
      }
    }
  }

  void _restoreConcerts(String? raw) {
    if (raw == null || raw.isEmpty) return;
    final list = jsonDecode(raw) as List<dynamic>;
    for (final entry in list) {
      final map = entry as Map<String, dynamic>;
      final concert = ConcertModel(
        name: map['name'] as String? ?? '',
        posterImageUrl: map['posterImageUrl'] as String? ?? '',
        id: map['id'] as String? ?? '',
        kopisId: map['kopisId'] as String?,
      );
      if (concert.name.isNotEmpty) {
        _concerts[concert.name] = concert;
      }
    }
  }

  Future<void> toggleArtist(ArtistModel artist) async {
    if (_artists.containsKey(artist.name)) {
      _artists.remove(artist.name);
    } else {
      _artists[artist.name] = artist;
    }
    notifyListeners();
    await _persistArtists();
    await _pushArtistsToServer();
  }

  Future<void> toggleConcert(ConcertModel concert) async {
    if (_concerts.containsKey(concert.name)) {
      _concerts.remove(concert.name);
    } else {
      _concerts[concert.name] = concert;
    }
    notifyListeners();
    await _persistConcerts();
    await _pushConcertsToServer();
  }

  Future<void> removeArtist(String name) async {
    if (_artists.remove(name) == null) return;
    notifyListeners();
    await _persistArtists();
    await _pushArtistsToServer();
  }

  Future<void> removeConcert(String name) async {
    if (_concerts.remove(name) == null) return;
    notifyListeners();
    await _persistConcerts();
    await _pushConcertsToServer();
  }

  Future<void> _persistArtists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(
        _artists.values
            .map((a) => {'name': a.name, 'profileImageUrl': a.profileImageUrl})
            .toList(),
      );
      await prefs.setString(_artistsPrefsKey, encoded);
    } catch (_) {}
  }

  Future<void> _persistConcerts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(
        _concerts.values
            .map(
              (c) => {
                'name': c.name,
                'posterImageUrl': c.posterImageUrl,
                'id': c.id,
                'kopisId': c.kopisId,
              },
            )
            .toList(),
      );
      await prefs.setString(_concertsPrefsKey, encoded);
    } catch (_) {}
  }

  /// 현재 아티스트 찜 목록을 서버에 전체 반영합니다(해제 포함).
  /// 실패해도 로컬 상태는 유지되고, 다음 변경/동기화 때 다시 반영됩니다.
  Future<void> _pushArtistsToServer() async {
    try {
      await _social.replaceArtistFollows(_artists.keys.toList());
    } catch (_) {}
  }

  /// 현재 공연 찜 목록을 서버에 전체 반영합니다. 백엔드가 공연 UUID를
  /// 요구하므로, UUID가 없는 항목(구버전 로컬 저장 등)은 제외됩니다.
  Future<void> _pushConcertsToServer() async {
    try {
      await _social.replaceConcertFollows([
        for (final c in _concerts.values)
          if (c.id.isNotEmpty)
            {'concert_id': c.id, 'kopis_concert_id': c.kopisId},
      ]);
    } catch (_) {}
  }
}
