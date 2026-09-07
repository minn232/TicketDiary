import 'dart:async';

import '../models/artist_model.dart';
import 'api_client.dart';

/// 아티스트 이름으로 검색하는 서비스의 인터페이스.
abstract class ArtistSearchService {
  /// [query]와 일치하는 아티스트를 연관성이 높은 순서로 반환합니다.
  /// [query]가 비어있으면 빈 리스트를 반환합니다.
  Future<List<ArtistModel>> search(String query);
}

// [백엔드 수정]
// `GET /artists/search`(DB 기준) 신규 연동 - 기존 `/concerts/search`(KOPIS 실시간, 종료된
// 공연만 있는 아티스트는 검색 안 됐음) 워크어라운드를 대체. 정렬/사진 첨부는 서버가 처리.
class BackendArtistSearchService implements ArtistSearchService {
  BackendArtistSearchService({ApiClient? client})
      : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  @override
  Future<List<ArtistModel>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final json = await _client.get('/artists/search?q=${Uri.encodeQueryComponent(q)}');
    final list = json['results'] as List<dynamic>? ?? const [];
    return [
      for (final e in list)
        ArtistModel(
          name: (e as Map<String, dynamic>)['name'] as String,
          profileImageUrl: e['profile_image_url'] as String? ?? '',
        ),
    ];
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
