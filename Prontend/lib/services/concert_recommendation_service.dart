// [백엔드 수정]
// 찜 공연 추천 API(GET /recommendations/concerts) 신규 연동.

import '../models/concert_model.dart';
import '../models/ticket_scan.dart' show ConcertResponse;
import 'api_client.dart';

/// 찜 공연 추천 조회 서비스 인터페이스.
abstract class ConcertRecommendationService {
  /// 인기 높은 순(앱 내 찜+티켓 등록 수 기준) 추천 공연 목록. 없으면 빈 리스트.
  Future<List<ConcertModel>> getRecommendations({int limit = 20});
}

/// 백엔드 `GET /recommendations/concerts` 기반 구현체. 이미 찜했거나 티켓
/// 등록한 공연은 서버가 미리 제외해서 응답합니다.
class BackendConcertRecommendationService implements ConcertRecommendationService {
  BackendConcertRecommendationService({ApiClient? client})
      : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  @override
  Future<List<ConcertModel>> getRecommendations({int limit = 20}) async {
    final list = await _client.getList('/recommendations/concerts?limit=$limit');
    return [
      for (final entry in list)
        _toConcertModel(ConcertResponse.fromJson(entry as Map<String, dynamic>)),
    ];
  }

  ConcertModel _toConcertModel(ConcertResponse c) => ConcertModel(
        name: c.name,
        posterImageUrl: c.posterUrl ?? '',
        id: c.id,
        kopisId: c.kopisId,
        venue: c.venue,
        startDate: c.startDate,
        endDate: c.endDate,
        artistName: c.artistName,
        ticketingDate: c.ticketingDate,
        ticketingPhases: c.ticketingPhases,
        ticketingLinks: c.ticketingLinks,
      );
}
