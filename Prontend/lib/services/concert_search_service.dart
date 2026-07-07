import '../models/concert_model.dart';

/// 공연 이름으로 검색하는 서비스의 인터페이스.
///
/// 실제 백엔드 API가 준비되면, 이 인터페이스를 구현하는 새 클래스로 교체하면
/// 검색 화면 쪽 코드는 그대로 재사용할 수 있습니다.
abstract class ConcertSearchService {
  /// [query]와 일치하는 공연을 연관성이 높은 순서로 반환합니다.
  /// [query]가 비어있으면 빈 리스트를 반환합니다.
  Future<List<ConcertModel>> search(String query);
}

/// 실제 백엔드 연동 전까지 사용하는 목(mock) 구현체.
class MockConcertSearchService implements ConcertSearchService {
  const MockConcertSearchService();

  static const List<ConcertModel> _mockConcerts = [
    ConcertModel(name: 'IU HEREH WORLD TOUR', posterImageUrl: ''),
    ConcertModel(name: 'BTS PERMISSION TO DANCE', posterImageUrl: ''),
    ConcertModel(name: 'BLACKPINK BORN PINK', posterImageUrl: ''),
    ConcertModel(name: 'NewJeans FAN MEETING', posterImageUrl: ''),
    ConcertModel(name: 'aespa SYNK', posterImageUrl: ''),
    ConcertModel(name: 'SEVENTEEN FOLLOW TOUR', posterImageUrl: ''),
    ConcertModel(name: 'Stray Kids DOMINATE', posterImageUrl: ''),
    ConcertModel(name: 'TWICE READY TO BE', posterImageUrl: ''),
  ];

  @override
  Future<List<ConcertModel>> search(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];

    final matches = _mockConcerts
        .where((concert) => concert.name.toLowerCase().contains(normalized))
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
