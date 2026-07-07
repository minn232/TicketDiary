import '../models/artist_model.dart';

/// 아티스트 이름으로 검색하는 서비스의 인터페이스.
///
/// 실제 백엔드 API가 준비되면, 이 인터페이스를 구현하는 새 클래스로 교체하면
/// 검색 화면 쪽 코드는 그대로 재사용할 수 있습니다.
abstract class ArtistSearchService {
  /// [query]와 일치하는 아티스트를 연관성이 높은 순서로 반환합니다.
  /// [query]가 비어있으면 빈 리스트를 반환합니다.
  Future<List<ArtistModel>> search(String query);
}

/// 실제 백엔드 연동 전까지 사용하는 목(mock) 구현체.
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

    // 연관성 높은 순: 앞부분이 일치하는 이름 우선, 그다음 이름 길이가 짧은(더 근접한) 순.
    matches.sort((a, b) {
      final aStarts = a.name.toLowerCase().startsWith(normalized);
      final bStarts = b.name.toLowerCase().startsWith(normalized);
      if (aStarts != bStarts) return aStarts ? -1 : 1;
      return a.name.length.compareTo(b.name.length);
    });

    return matches;
  }
}
