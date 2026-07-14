/// 소식(뉴스 피드) 데이터 모델.
///
/// 백엔드 `GET /social/feed`의 `NewsFeedResponse`(schemas/social.py)를 그대로
/// 받아 화면용 필드로 변환합니다. 백엔드 피드는 "팔로우한 아티스트의 새 공연이
/// 등록됐다"는 알림 수준의 데이터(공연명/포스터/기간/공연장)만 담고 있어서,
/// 카드 요약([description])과 상세 본문([content])은 그 정보를 조합해 프론트에서
/// 만들어 채웁니다.
class NewsModel {
  /// 피드 항목 UUID(백엔드 `id`). 읽음 처리(`PATCH /social/feed/{id}/read`)에
  /// 사용합니다. 백엔드 연동 없이 만든 폴백 카드는 null입니다.
  final String? id;

  /// 연결된 공연 UUID(백엔드 `concert_id`).
  final String? concertId;

  /// 읽음 여부. 상세를 열어본 순간 로컬에서 먼저 true로 바꾸고 서버에도
  /// 반영하므로 mutable로 둡니다.
  bool isRead;

  final String artist;
  final String concert;
  final String imageUrl;

  /// 소식 한 줄 요약(폴라로이드 카드에 노출).
  final String description;

  /// 소식 상세(카드를 눌렀을 때 확장되는 화면)에 보여줄 줄글 본문.
  final String content;

  /// 소식 상세 화면에서 아티스트 이름과 본문 사이에 들어갈 이미지.
  final String articleImageUrl;

  NewsModel({
    required this.artist,
    required this.concert,
    required this.imageUrl,
    required this.description,
    this.content = '',
    this.articleImageUrl = '',
    this.id,
    this.concertId,
    this.isRead = true,
  });

  /// 백엔드 `NewsFeedResponse` JSON으로부터 생성합니다.
  ///
  /// ```json
  /// {
  ///   "id": "...", "user_id": "...", "concert_id": "...",
  ///   "artist_name": "IU", "is_read": false,
  ///   "concert": {
  ///     "id": "...", "name": "...", "poster_url": null,
  ///     "start_date": "...", "end_date": "...", "venue": "..."
  ///   }
  /// }
  /// ```
  factory NewsModel.fromFeedJson(Map<String, dynamic> json) {
    final artistName = json['artist_name'] as String? ?? '알 수 없는 아티스트';
    final concertJson = json['concert'] as Map<String, dynamic>?;

    final concertName = concertJson?['name'] as String? ?? '알 수 없는 공연';
    final posterUrl = concertJson?['poster_url'] as String? ?? '';
    final venue = concertJson?['venue'] as String?;
    final period = _formatPeriod(
      concertJson?['start_date'] as String?,
      concertJson?['end_date'] as String?,
    );

    final descriptionParts = <String>['새 공연이 등록됐어요!', ?period];

    final contentLines = <String>[
      '$artistName의 새 공연 <$concertName>이(가) 등록되었습니다.',
      '',
      if (period != null) '공연 기간  $period',
      '공연장  ${venue ?? '미정'}',
      '',
      '예매 일정과 상세 정보는 예매처에서 확인해주세요.',
    ];

    return NewsModel(
      id: json['id'] as String?,
      concertId: json['concert_id'] as String?,
      isRead: json['is_read'] as bool? ?? true,
      artist: artistName,
      concert: concertName,
      imageUrl: posterUrl,
      description: descriptionParts.join(' '),
      content: contentLines.join('\n'),
      articleImageUrl: posterUrl,
    );
  }

  /// ISO 날짜 문자열 두 개를 "2026.07.21" 또는 "2026.07.21 ~ 2026.07.23"
  /// 형태로 만듭니다. 파싱에 실패하면 null.
  static String? _formatPeriod(String? startRaw, String? endRaw) {
    final start = startRaw != null ? DateTime.tryParse(startRaw) : null;
    final end = endRaw != null ? DateTime.tryParse(endRaw) : null;
    if (start == null) return null;

    String fmt(DateTime d) =>
        '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

    final startText = fmt(start);
    if (end == null || fmt(end) == startText) return startText;
    return '$startText ~ ${fmt(end)}';
  }
}
