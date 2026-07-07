import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/artist_model.dart';
import '../models/concert_model.dart';

/// 사용자가 "찜"한 아티스트/공연을 보관하는 전역 저장소.
///
/// 설정 > 선호 아티스트 / 찜 공연 화면에서 찜을 토글하면 여기에 반영되고,
/// 소식 탭은 이 목록을 기준으로 어떤 아티스트/공연의 소식만 불러올지 결정합니다.
/// 백엔드 연동 전까지는 기기 로컬(SharedPreferences)에 저장해두고,
/// 나중에 백엔드에 찜 목록 API가 생기면 이 클래스 내부만 교체하면 됩니다.
class FavoritesStore extends ChangeNotifier {
  FavoritesStore._();

  static final FavoritesStore instance = FavoritesStore._();

  static const _artistsPrefsKey = 'favorite_artists_v1';
  static const _concertsPrefsKey = 'favorite_concerts_v1';

  final Map<String, ArtistModel> _artists = {};
  final Map<String, ConcertModel> _concerts = {};

  bool _loaded = false;

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
  }

  Future<void> toggleConcert(ConcertModel concert) async {
    if (_concerts.containsKey(concert.name)) {
      _concerts.remove(concert.name);
    } else {
      _concerts[concert.name] = concert;
    }
    notifyListeners();
    await _persistConcerts();
  }

  Future<void> removeArtist(String name) async {
    if (_artists.remove(name) == null) return;
    notifyListeners();
    await _persistArtists();
  }

  Future<void> removeConcert(String name) async {
    if (_concerts.remove(name) == null) return;
    notifyListeners();
    await _persistConcerts();
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
            .map((c) => {'name': c.name, 'posterImageUrl': c.posterImageUrl})
            .toList(),
      );
      await prefs.setString(_concertsPrefsKey, encoded);
    } catch (_) {}
  }
}
