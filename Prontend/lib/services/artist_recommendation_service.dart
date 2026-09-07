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
          // [백엔드 수정]
          // profile_image_url 파싱 추가(그동안 빈 문자열 고정이라 추천
          // 그리드엔 항상 플레이스홀더만 뜸 - 정규화된 아티스트만 채워짐).
          profileImageUrl: entry['profile_image_url'] as String? ?? '',
        ),
    ];
  }
}
