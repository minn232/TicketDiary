import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/artist_model.dart';
import '../models/concert_model.dart';
import '../models/ticket_scan.dart';
import 'api_client.dart';
import 'auth_service.dart';
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
  // [백엔드 수정]
  // 로그인 유저가 바뀌어도(게스트→카카오, 카카오→다른 계정) load()/
  // syncFromServer()가 한 번 실행되면 다시 안 도는 문제 - AuthService를
  // 구독해 유저 id가 바뀌면 다시 불러옴(DiaryScreen과 동일 패턴).
  FavoritesStore._() {
    AuthService.instance.addListener(_onAuthChanged);
  }

  static final FavoritesStore instance = FavoritesStore._();

  static const _artistsPrefsKey = 'favorite_artists_v1';
  static const _concertsPrefsKey = 'favorite_concerts_v1';

  final SocialService _social = SocialService();

  final Map<String, ArtistModel> _artists = {};
  final Map<String, ConcertModel> _concerts = {};

  bool _loaded = false;
  bool _serverSynced = false;

  /// 마지막으로 load()/syncFromServer()를 실행했던 유저 id.
  String? _loadedForUserId;

  void _onAuthChanged() {
    final currentUserId = AuthService.instance.userId;
    if (currentUserId == _loadedForUserId) return;
    _loadedForUserId = currentUserId;

    _artists.clear();
    _concerts.clear();
    _loaded = false;
    _serverSynced = false;
    _revision++;
    notifyListeners();

    unawaited(load());
    unawaited(syncFromServer());
  }

  /// 찜 목록(또는 그 표시 내용)이 바뀔 때마다 1씩 늘어납니다.
  /// [NewsCacheStore]가 이 값을 캐시와 함께 저장해뒀다가, 저장 당시 값과
  /// 지금 값이 다르면(=찜을 바꾼 뒤 첫 방문) 캐시를 못 미더운 것으로 보고
  /// 건너뛰어 항상 최신 소식을 다시 불러오게 합니다.
  int _revision = 0;
  int get revision => _revision;

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

    // venue/startDate 필드가 추가되기 전에 저장된 옛날 찜 공연은 그 값들이
    // 계속 비어 있으므로(로컬 캐시라 자동으로 안 고쳐짐), 한 번씩 상세
    // 조회로 보충을 시도합니다.
    for (final concert in _concerts.values.toList()) {
      unawaited(_backfillMissingConcertFields(concert));
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
              venue: detail.venue,
              startDate: detail.startDate,
              endDate: detail.endDate,
              artistName: detail.artistName,
              ticketingDate: detail.ticketingDate,
              ticketingLinks: detail.ticketingLinks,
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
      _revision++;
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
      final startDateRaw = map['startDate'] as String?;
      final endDateRaw = map['endDate'] as String?;
      final ticketingDateRaw = map['ticketingDate'] as String?;
      final concert = ConcertModel(
        name: map['name'] as String? ?? '',
        posterImageUrl: map['posterImageUrl'] as String? ?? '',
        id: map['id'] as String? ?? '',
        kopisId: map['kopisId'] as String?,
        venue: map['venue'] as String?,
        startDate: startDateRaw != null ? DateTime.tryParse(startDateRaw) : null,
        endDate: endDateRaw != null ? DateTime.tryParse(endDateRaw) : null,
        artistName: (map['artistName'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const [],
        ticketingDate: ticketingDateRaw != null
            ? DateTime.tryParse(ticketingDateRaw)
            : null,
        ticketingLinks: (map['ticketingLinks'] as Map<String, dynamic>?)
            ?.map((key, value) => MapEntry(key, value as String)),
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
    _revision++;
    notifyListeners();
    await _persistArtists();
    await _pushArtistsToServer();
  }

  // [백엔드 수정]
  // 이미 티켓 등록된 공연은 서버가 찜 저장을 거부. 그 경우 로컬 하트도
  // 다시 꺼주고 true를 반환해서, 호출부가 안내 문구를 띄울 수 있게 함.
  Future<bool> toggleConcert(ConcertModel concert) async {
    final adding = !_concerts.containsKey(concert.name);
    if (!adding) {
      _concerts.remove(concert.name);
    } else {
      _concerts[concert.name] = concert;
    }
    _revision++;
    notifyListeners();
    await _persistConcerts();
    final rejectedIds = await _pushConcertsToServer();
    final rejected = adding && rejectedIds.contains(concert.id);
    if (rejected) {
      _concerts.remove(concert.name);
      _revision++;
      notifyListeners();
      await _persistConcerts();
      return true;
    }
    // 검색 목록 응답엔 티케팅 오픈일이 항상 비어 있으므로, 방금 찜한 공연은
    // 상세 조회로 한 번 더 확인해봅니다(크롤러가 이미 수집해뒀을 수 있음).
    if (adding) {
      unawaited(_backfillMissingConcertFields(concert));
    }
    return false;
  }

  /// [concert]에 공연장/기간/출연진/티케팅 오픈일 중 비어 있는 게 있으면
  /// 상세 조회로 한 번 보충합니다. 티케팅 오픈일은 대부분 크롤러가 아직
  /// 수집 못 해 계속 비어 있을 수 있지만, venue/startDate/artistName은
  /// KOPIS 상세에 보통 존재하므로 옛날 로컬 데이터를 채우는 역할도 합니다.
  Future<void> _backfillMissingConcertFields(ConcertModel concert) async {
    final kopisId = concert.kopisId;
    final missingSomething = concert.venue == null ||
        concert.startDate == null ||
        concert.ticketingDate == null ||
        concert.ticketingLinks == null;
    if (!missingSomething || kopisId == null || kopisId.isEmpty) return;

    try {
      final json = await _client.get('/concerts/$kopisId');
      final detail = ConcertResponse.fromJson(json);

      final current = _concerts[concert.name];
      if (current == null) return; // 그 사이 찜 해제됐으면 무시
      _concerts[concert.name] = ConcertModel(
        name: current.name,
        posterImageUrl: current.posterImageUrl,
        id: current.id,
        kopisId: current.kopisId,
        venue: current.venue ?? detail.venue,
        startDate: current.startDate ?? detail.startDate,
        endDate: current.endDate ?? detail.endDate,
        artistName:
            current.artistName.isNotEmpty ? current.artistName : detail.artistName,
        ticketingDate: current.ticketingDate ?? detail.ticketingDate,
        ticketingLinks: current.ticketingLinks ?? detail.ticketingLinks,
      );
      _revision++;
      notifyListeners();
      await _persistConcerts();
    } catch (_) {
      // 실패해도 무시 - 기존 값 그대로(대부분 "미정") 남습니다.
    }
  }

  Future<void> removeArtist(String name) async {
    if (_artists.remove(name) == null) return;
    _revision++;
    notifyListeners();
    await _persistArtists();
    await _pushArtistsToServer();
  }

  Future<void> removeConcert(String name) async {
    if (_concerts.remove(name) == null) return;
    _revision++;
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
                'venue': c.venue,
                'startDate': c.startDate?.toIso8601String(),
                'endDate': c.endDate?.toIso8601String(),
                'artistName': c.artistName,
                'ticketingDate': c.ticketingDate?.toIso8601String(),
                'ticketingLinks': c.ticketingLinks,
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
  //
  // [백엔드 수정]
  // 서버가 이미 티켓 등록된 공연은 저장하지 않고 걸러서 돌려주므로, 보낸
  // concert_id 중 응답에 없는 것들을 반환(호출부의 로컬 정정용).
  Future<Set<String>> _pushConcertsToServer() async {
    final requested = [
      for (final c in _concerts.values)
        if (c.id.isNotEmpty) {'concert_id': c.id, 'kopis_concert_id': c.kopisId},
    ];
    try {
      final saved = await _social.replaceConcertFollows(requested);
      final savedIds = {for (final e in saved) e['concert_id'] as String};
      final requestedIds = {for (final e in requested) e['concert_id'] as String};
      return requestedIds.difference(savedIds);
    } catch (_) {
      return {};
    }
  }
}
