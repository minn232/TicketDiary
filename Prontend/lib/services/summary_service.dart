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
  final double standingRatio;
  final double seatRatio;
  final double firstConcertRatio;
  final double lastConcertRatio;

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

  /// 백엔드는 스탠딩/좌석/첫콘/막콘을 비율이 아닌 개수(`standing_count` 등)로
  /// 주기 때문에, 여기서 `concert_count` 대비 비율로 변환합니다.
  factory SummaryModel.fromJson(Map<String, dynamic> json) {
    final concertCount = json['concert_count'] as int? ?? 0;
    double ratio(dynamic count) =>
        concertCount == 0 ? 0.0 : (count as int? ?? 0) / concertCount;

    return SummaryModel(
      concertCount: concertCount,
      totalSpending: json['total_spent'] as int? ?? 0,
      songCount: json['song_count'] as int? ?? 0,
      favoriteGenre: json['top_genre'] as String? ?? '-',
      visitedArtists: (json['artists'] as List? ?? const [])
          .map((e) => ArtistVisit.fromJson(e as Map<String, dynamic>))
          .toList(),
      standingRatio: ratio(json['standing_count']),
      seatRatio: ratio(json['seated_count']),
      firstConcertRatio: ratio(json['first_day_count']),
      lastConcertRatio: ratio(json['last_day_count']),
    );
  }
}

/// 백엔드 `GET /summary` API와 통신하는 서비스.
class SummaryService {
  SummaryService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  /// 결산 조회. [period]는 백엔드가 받는 값 그대로(`6m`/`1y`/`all`) 넘깁니다.
  Future<SummaryModel> fetchSummary({String period = 'all'}) async {
    final json = await _client.get('/summary?period=$period');
    return SummaryModel.fromJson(json);
  }
}
