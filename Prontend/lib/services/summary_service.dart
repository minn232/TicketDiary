import 'api_client.dart';

/// 결산 데이터 모델. 백엔드 `GET /summary` 응답과 대응합니다.
class SummaryModel {
  final int concertCount;
  final int totalSpending;
  final int songCount;
  final String favoriteGenre;
  final List<String> visitedArtists;
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
      visitedArtists: List<String>.from(json['artists'] as List? ?? const []),
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

  /// 결산 조회. 기간 선택 UI가 없으므로 항상 전체 기간(`all`)을 조회합니다.
  Future<SummaryModel> fetchSummary() async {
    final json = await _client.get('/summary?period=all');
    return SummaryModel.fromJson(json);
  }
}
