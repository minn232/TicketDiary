import 'dart:async';

import '../models/artist_model.dart';
import '../models/ticket_scan.dart';
import 'api_client.dart';

/// 아티스트 이름으로 검색하는 서비스의 인터페이스.
abstract class ArtistSearchService {
  /// [query]와 일치하는 아티스트를 연관성이 높은 순서로 반환합니다.
  /// [query]가 비어있으면 빈 리스트를 반환합니다.
  Future<List<ArtistModel>> search(String query);
}

/// 백엔드 기반 아티스트 검색 구현체.
///
/// 백엔드에 아티스트 전용 검색 API가 없어서, 공연 검색
/// (`GET /concerts/search?keyword=`) 결과에서 아티스트를 추출합니다.
/// KOPIS 공연명에는 보통 아티스트 이름이 들어가므로("아이유 콘서트" 등)
/// 아티스트 이름으로 검색해도 관련 공연이 잡힙니다.
///
/// 단, 목록 검색 응답에는 `artist_name`이 비어 있는 경우가 많아
/// (백엔드가 상세 조회 때만 출연진을 파싱), 아티스트가 비어 있는 상위
/// 공연 몇 건은 상세(`GET /concerts/{kopis_id}`)를 병렬로 추가 조회해
/// 아티스트 이름을 보충합니다.
///
/// 아티스트 프로필 이미지는 백엔드/KOPIS에 데이터 소스가 없어 항상 빈
/// 문자열로 둡니다(화면에서 사람 아이콘 플레이스홀더 표시). 공연 포스터로
/// 대체하지 않습니다 — 이후 백엔드에 아티스트 이미지 API가 생기면 여기서
/// 채워주면 됩니다.
class BackendArtistSearchService implements ArtistSearchService {
  BackendArtistSearchService({ApiClient? client})
      : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  /// artist_name이 비어 있을 때 상세 조회로 보충할 최대 공연 수.
  static const int _maxDetailLookups = 3;

  @override
  Future<List<ArtistModel>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final list = await _client.getList(
      '/concerts/search?keyword=${Uri.encodeQueryComponent(q)}',
    );
    final concerts = [
      for (final e in list) ConcertResponse.fromJson(e as Map<String, dynamic>),
    ];

    final seen = <String>{};
    final results = <ArtistModel>[];
    void addArtist(String name) {
      final trimmed = name.trim();
      final key = trimmed.toLowerCase();
      if (trimmed.isEmpty || seen.contains(key)) return;
      seen.add(key);
      results.add(ArtistModel(name: trimmed, profileImageUrl: ''));
    }

    // 1) 목록 응답에 이미 아티스트가 있는 공연부터 수집
    for (final c in concerts) {
      for (final a in c.artistName) {
        addArtist(a);
      }
    }

    // 2) 아티스트가 비어 있는 상위 공연 몇 건은 상세 조회로 보충(병렬)
    final needDetail = concerts
        .where((c) => c.artistName.isEmpty && c.kopisId != null)
        .take(_maxDetailLookups)
        .toList();
    final details = await Future.wait([
      for (final c in needDetail)
        _client
            .get('/concerts/${c.kopisId}')
            .then<ConcertResponse?>(
              (json) => ConcertResponse.fromJson(json),
            )
            .catchError((_) => null),
    ]);
    for (final detail in details) {
      if (detail == null) continue;
      for (final a in detail.artistName) {
        addArtist(a);
      }
    }

    // 질의어를 포함하는 아티스트를 앞으로, 그 안에서는 이름이 짧은 순으로.
    final nq = q.toLowerCase();
    results.sort((a, b) {
      final aMatch = a.name.toLowerCase().contains(nq);
      final bMatch = b.name.toLowerCase().contains(nq);
      if (aMatch != bMatch) return aMatch ? -1 : 1;
      return a.name.length.compareTo(b.name.length);
    });

    return results;
  }
}

/// 실제 백엔드 연동 전 테스트용 목(mock) 구현체.
class MockArtistSearchService implements ArtistSearchService {
  const MockArtistSearchService();

  static const List<ArtistModel> _mockArtists = [
    ArtistModel(name: 'IU', profileImageUrl: ''),
    ArtistModel(name: 'BTS', profileImageUrl: ''),
    ArtistModel(name: 'BLACKPINK', profileImageUrl: ''),
    ArtistModel(name: 'NewJeans', profileImageUrl: ''),
    ArtistModel(name: 'aespa', profileImageUrl: ''),
    ArtistModel(name: 'SEVENTEEN', profileImageUrl: ''),
    ArtistModel(name: 'Stray Kids', profileImageUrl: ''),
    ArtistModel(name: 'TWICE', profileImageUrl: ''),
    ArtistModel(name: 'IVE', profileImageUrl: ''),
    ArtistModel(name: 'LE SSERAFIM', profileImageUrl: ''),
  ];

  @override
  Future<List<ArtistModel>> search(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];

    final matches = _mockArtists
        .where((artist) => artist.name.toLowerCase().contains(normalized))
        .toList();

    matches.sort((a, b) {
      final aStarts = a.name.toLowerCase().startsWith(normalized);
      final bStarts = b.name.toLowerCase().startsWith(normalized);
      if (aStarts != bStarts) return aStarts ? -1 : 1;
      return a.name.length.compareTo(b.name.length);
    });

    return matches;
  }
}
