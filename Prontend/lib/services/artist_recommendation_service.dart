// [백엔드 수정]
// 아티스트 추천 API(GET /recommendations/artists) 신규 연동.

import '../models/artist_model.dart';
import 'api_client.dart';

/// 아티스트 추천 조회 서비스 인터페이스.
abstract class ArtistRecommendationService {
  /// 점수 높은 순 추천 아티스트 목록. 없으면 빈 리스트.
  Future<List<ArtistModel>> getRecommendations({int limit = 20});
}

/// 백엔드 `GET /recommendations/artists` 기반 구현체.
class BackendArtistRecommendationService implements ArtistRecommendationService {
  BackendArtistRecommendationService({ApiClient? client})
      : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  @override
  Future<List<ArtistModel>> getRecommendations({int limit = 20}) async {
    final json = await _client.get('/recommendations/artists?limit=$limit');
    final list = json['recommendations'] as List<dynamic>? ?? const [];
    return [
      for (final entry in list)
        ArtistModel(
          name: (entry as Map<String, dynamic>)['artist_name'] as String,
          profileImageUrl: '',
        ),
    ];
  }
}
