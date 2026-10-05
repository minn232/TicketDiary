import 'dart:ui';
import '../models/summary_map.dart';
import 'api_client.dart';

// [백엔드 수정]
// 관람 아티스트가 이름만 있던 걸 몇 회 관람했는지(count)까지 주도록 바뀜(내림차순 정렬).
/// 관람 아티스트 한 명 + 관람 횟수.
class ArtistVisit {
  final String name;
  final int count;

  const ArtistVisit({required this.name, required this.count});

  factory ArtistVisit.fromJson(Map<String, dynamic> json) => ArtistVisit(
    name: json['name'] as String? ?? '',
    count: json['count'] as int? ?? 0,
  );
}

/// 결산 데이터 모델. 백엔드 `GET /summary` 응답과 대응합니다.
class SummaryModel {
  final int concertCount;
  final int totalSpending;
  final int songCount;
  final String favoriteGenre;
  final List<ArtistVisit> visitedArtists;
  // 0~1, 대상 티켓이 없으면 null(화면엔 '-')
  final double? standingRatio;
  final double? seatRatio;
  final double? firstConcertRatio;
  final double? lastConcertRatio;

  SummaryModel({
    required this.concertCount,
    required this.totalSpending,
    required this.songCount,
    required this.favoriteGenre,
    required this.visitedArtists,
    required this.standingRatio,
    required this.seatRatio,
    required this.firstConcertRatio,
    required this.lastConcertRatio,
  });

  // [백엔드 수정]
  // 스탠딩/좌석, 첫콘/막콘을 `*_percent`(대상 없으면 null)로 받음.
  factory SummaryModel.fromJson(Map<String, dynamic> json) {
    final concertCount = json['concert_count'] as int? ?? 0;
    double? ratio(dynamic percent) => percent is int ? percent / 100 : null;
    // [백엔드 수정] 동률이면 `top_genres` 전부 표시.
    final topGenres = (json['top_genres'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final favoriteGenre = topGenres.isNotEmpty
        ? topGenres.join(', ')
        : (json['top_genre'] as String? ?? '-');

    return SummaryModel(
      concertCount: concertCount,
      totalSpending: json['total_spent'] as int? ?? 0,
      songCount: json['song_count'] as int? ?? 0,
      favoriteGenre: favoriteGenre,
      visitedArtists: (json['artists'] as List? ?? const [])
          .map((e) => ArtistVisit.fromJson(e as Map<String, dynamic>))
          .toList(),
      standingRatio: ratio(json['standing_percent']),
      seatRatio: ratio(json['seated_percent']),
      firstConcertRatio: ratio(json['first_day_percent']),
      lastConcertRatio: ratio(json['last_day_percent']),
    );
  }
}

/// 백엔드 `GET /summary` API와 통신하는 서비스.
class SummaryService {
  SummaryService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  Future<RegionalSummary> fetchRegions({String period = 'all'}) async {
    return RegionalSummary.fromJson(
      await _client.get('/summary/regions?period=$period'),
    );
  }

  /// 결산 조회. [period]는 백엔드가 받는 값 그대로(`6m`/`1y`/`all`) 넘깁니다.
  Future<SummaryModel> fetchSummary({String period = 'all'}) async {
    final json = await _client.get('/summary?period=$period');
    return SummaryModel.fromJson(json);
  }
}

/// Coordinates are resolved on the server from the actual KOPIS facility.
/// Unknown locations are explicit, so failed lookups never become fake visits.
class RegionalSummary {
  final List<SummaryMapVisit> visits;
  final int total;
  final int unresolved;
  const RegionalSummary({
    required this.visits,
    required this.total,
    required this.unresolved,
  });
  factory RegionalSummary.fromJson(Map<String, dynamic> json) =>
      RegionalSummary(
        total: json['concert_count'] as int,
        unresolved: json['unresolved_count'] as int,
        visits: (json['locations'] as List)
            .map(
              (v) => SummaryMapVisit(
                Offset(
                  (v['longitude'] as num).toDouble(),
                  (v['latitude'] as num).toDouble(),
                ),
                v['count'] as int,
              ),
            )
            .toList(),
      );
}
