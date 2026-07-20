import '../models/concert_model.dart';
import '../models/ticket_scan.dart';
import 'api_client.dart';

/// 공연 이름으로 검색하는 서비스의 인터페이스.
abstract class ConcertSearchService {
  /// [query]와 일치하는 공연을 연관성이 높은 순서로 반환합니다.
  /// [query]가 비어있으면 빈 리스트를 반환합니다.
  Future<List<ConcertModel>> search(String query);
}

/// 백엔드 `GET /concerts/search?keyword=`(KOPIS 실시간 검색) 구현체.
/// 응답의 공연 UUID/KOPIS ID를 함께 담아, 찜 시 서버 동기화
/// (`PATCH /social/concerts`)에 그대로 쓸 수 있게 합니다.
class BackendConcertSearchService implements ConcertSearchService {
  BackendConcertSearchService({ApiClient? client})
      : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  @override
  Future<List<ConcertModel>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final list = await _client.getList(
      '/concerts/search?keyword=${Uri.encodeQueryComponent(q)}',
    );
    final concerts = [
      for (final e in list) ConcertResponse.fromJson(e as Map<String, dynamic>),
    ];

    // KOPIS가 이미 키워드로 걸러주지만, 질의어가 이름 앞부분에 오는 공연을
    // 우선하도록 가볍게 재정렬합니다.
    final nq = q.toLowerCase();
    concerts.sort((a, b) {
      final aStarts = a.name.toLowerCase().startsWith(nq);
      final bStarts = b.name.toLowerCase().startsWith(nq);
      if (aStarts != bStarts) return aStarts ? -1 : 1;
      return 0;
    });

    return [
      for (final c in concerts)
        ConcertModel(
          name: c.name,
          posterImageUrl: c.posterUrl ?? '',
          id: c.id,
          kopisId: c.kopisId,
          venue: c.venue,
          startDate: c.startDate,
          endDate: c.endDate,
          artistName: c.artistName,
          ticketingDate: c.ticketingDate,
        ),
    ];
  }
}

/// 실제 백엔드 연동 전 테스트용 목(mock) 구현체.
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
