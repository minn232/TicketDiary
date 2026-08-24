import 'concert_model.dart';

/// 소식(뉴스 피드) 데이터 모델.
///
/// 백엔드 `GET /social/feed`의 `NewsFeedResponse`(schemas/social.py)를 그대로
/// 받아 화면용 필드로 변환합니다. 백엔드 피드는 "팔로우한 아티스트의 새 공연이
/// 등록됐다"는 알림 수준의 데이터(공연명/포스터/기간/공연장)만 담고 있어서,
/// 카드 요약([description])과 상세 본문([contentTop]/[contentBottom])은 그
/// 정보를 조합해 프론트에서 만들어 채웁니다.
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

  /// 소식 상세(카드를 눌렀을 때 확장되는 화면)에 보여줄 줄글 본문 중
  /// [venue] 위쪽에 오는 부분(공연 기간까지).
  final String contentTop;

  /// 줄글 본문 중 [venue] 아래쪽에 오는 부분(티케팅 날짜 등).
  ///
  /// 공연장 정보는 [contentTop]/[contentBottom] 어디에도 포함되지 않고
  /// [venue]로 따로 빠져 있습니다 — 상세 화면에서 공연장 이름을 눌러
  /// 지도로 바로 이동할 수 있게 하려면 줄글 속 텍스트가 아니라 두 텍스트
  /// 사이에 끼워 넣는 별도의 탭 가능한 위젯으로 그려야 하기 때문입니다.
  final String contentBottom;

  /// 소식 상세 화면에서 아티스트 이름과 본문 사이에 들어갈 이미지.
  final String articleImageUrl;

  /// 공연장 이름. 상세 화면에서 탭하면 지도 앱으로 검색해 이동합니다.
  final String? venue;

  // [백엔드 수정]
  // 예매처 바로가기 버튼용(키: YES24/INTERPARK/TICKETLINK/MELON).
  final Map<String, String>? ticketingLinks;

  /// 공연 시작일. 소식 탭 카드의 D-day 표시와 정렬(공연이 가까운 순)
  /// 기준으로 씁니다. 정보가 없으면 null(정렬 시 맨 뒤로 밀림).
  final DateTime? concertDate;

  /// true면 [FavoritesStore]의 찜 공연을 그대로 보여주는 카드입니다.
  /// 카드 좌상단 라벨을 아티스트 이름 대신 공연 D-day로 표시하는 데 씁니다.
  final bool isFavoritedConcert;

  /// 상세 화면 정보 타일용 구조화 값 — 공연 기간(예: "2026.09.04 ~ 09.06").
  final String? periodText;

  /// 상세 화면 정보 타일용 구조화 값 — 티켓팅 상태(예: "D-3"/"예매 중"/"미정").
  final String? ticketingText;

  /// 공연 종료일. 공연 기간 타일을 눌렀을 때 캘린더에서 [concertDate]~여기까지
  /// 색칠하는 데 씁니다.
  final DateTime? concertEndDate;

  /// 티켓팅(예매 오픈) 날짜. 티켓팅 타일을 눌렀을 때 캘린더에서 이 날에
  /// 색칠하는 데 씁니다.
  final DateTime? ticketingDate;

  NewsModel({
    required this.artist,
    required this.concert,
    required this.imageUrl,
    required this.description,
    this.contentTop = '',
    this.contentBottom = '',
    this.articleImageUrl = '',
    this.venue,
    this.id,
    this.concertId,
    this.isRead = true,
    this.ticketingLinks,
    this.concertDate,
    this.isFavoritedConcert = false,
    this.periodText,
    this.ticketingText,
    this.concertEndDate,
    this.ticketingDate,
  });

  /// 카드 좌상단에 보여줄 공연 D-day 라벨. 날짜 정보가 없으면 "미정".
  String get concertDDayLabel => _concertDDay(concertDate);

  static String _concertDDay(DateTime? date) {
    if (date == null) return '미정';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = target.difference(today).inDays;
    if (diff > 0) return 'D-$diff';
    if (diff == 0) return 'D-DAY';
    return 'D+${-diff}';
  }

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
    final ticketingLinks =
        (concertJson?['ticketing_links'] as Map<String, dynamic>?)
            ?.map((key, value) => MapEntry(key, value as String));
    final period = _formatPeriod(
      concertJson?['start_date'] as String?,
      concertJson?['end_date'] as String?,
    );

    final descriptionParts = <String>['새 공연이 등록됐어요!', ?period];

    final contentTopLines = <String>[
      '$artistName의 새 공연 <$concertName>이(가) 등록되었습니다.',
      '',
      if (period != null) '공연 기간  $period',
    ];
    const contentBottomLines = <String>[
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
      contentTop: contentTopLines.join('\n'),
      contentBottom: contentBottomLines.join('\n'),
      articleImageUrl: posterUrl,
      venue: venue,
      ticketingLinks: ticketingLinks,
      concertDate: DateTime.tryParse(concertJson?['start_date'] as String? ?? ''),
      periodText: period,
      concertEndDate:
          DateTime.tryParse(concertJson?['end_date'] as String? ?? ''),
    );
  }

  /// 찜한 공연([ConcertModel])을 그대로 카드로 보여주기 위해 생성합니다.
  /// 백엔드 소식 피드(아티스트 매칭)와 달리 순수 로컬 표시용이라 [id]가 없어
  /// 읽음 처리 대상이 아니고, 그래서 [isRead]도 항상 true(NEW 배지 없음)로 둡니다.
  ///
  /// 카드 요약([description])은 제목 아래에 티케팅(예매) 오픈일까지 남은
  /// 일수를 D-day로 보여줍니다. 상세 본문에는 출연진/공연 기간
  /// ([contentTop])과 티케팅 날짜([contentBottom])를 채워 넣고, 그 사이에
  /// 공연장([venue])이 들어갑니다.
  factory NewsModel.fromFavoritedConcert(ConcertModel concert) {
    final period = _formatPeriod(
      concert.startDate?.toIso8601String(),
      concert.endDate?.toIso8601String(),
    );
    final dDay = _ticketingDDay(concert.ticketingDate);
    final artists = concert.artistName.isNotEmpty
        ? concert.artistName.join(', ')
        : null;

    final contentTopLines = <String>[
      if (artists != null) '출연진  $artists',
      if (period != null) '공연 기간  $period',
    ];

    return NewsModel(
      concertId: concert.id.isNotEmpty ? concert.id : null,
      isRead: true,
      artist: '찜한 공연',
      concert: concert.name,
      imageUrl: concert.posterImageUrl,
      description: '티케팅 날짜  $dDay',
      contentTop: contentTopLines.join('\n'),
      contentBottom: '티케팅 날짜  $dDay',
      articleImageUrl: concert.posterImageUrl,
      venue: concert.venue,
      ticketingLinks: concert.ticketingLinks,
      concertDate: concert.startDate,
      isFavoritedConcert: true,
      periodText: period,
      ticketingText: dDay,
      concertEndDate: concert.endDate,
      ticketingDate: concert.ticketingDate,
    );
  }

  /// [NewsCacheStore]에 저장하기 위한 직렬화. 화면에 보여줄 형태로 이미
  /// 다 가공된 필드를 그대로 저장해서, 캐시를 다시 불러올 때(백엔드/찜
  /// 목록을 다시 조회하지 않고) 값만 그대로 복원하면 됩니다.
  Map<String, dynamic> toJson() => {
    'id': id,
    'concertId': concertId,
    'isRead': isRead,
    'artist': artist,
    'concert': concert,
    'imageUrl': imageUrl,
    'description': description,
    'contentTop': contentTop,
    'contentBottom': contentBottom,
    'articleImageUrl': articleImageUrl,
    'venue': venue,
    'ticketingLinks': ticketingLinks,
    'concertDate': concertDate?.toIso8601String(),
    'isFavoritedConcert': isFavoritedConcert,
    'periodText': periodText,
    'ticketingText': ticketingText,
    'concertEndDate': concertEndDate?.toIso8601String(),
    'ticketingDate': ticketingDate?.toIso8601String(),
  };

  factory NewsModel.fromCacheJson(Map<String, dynamic> json) {
    return NewsModel(
      id: json['id'] as String?,
      concertId: json['concertId'] as String?,
      isRead: json['isRead'] as bool? ?? true,
      artist: json['artist'] as String? ?? '',
      concert: json['concert'] as String? ?? '',
      imageUrl: json['imageUrl'] as String? ?? '',
      description: json['description'] as String? ?? '',
      contentTop: json['contentTop'] as String? ?? '',
      contentBottom: json['contentBottom'] as String? ?? '',
      articleImageUrl: json['articleImageUrl'] as String? ?? '',
      venue: json['venue'] as String?,
      ticketingLinks: (json['ticketingLinks'] as Map<String, dynamic>?)
          ?.map((key, value) => MapEntry(key, value as String)),
      concertDate: json['concertDate'] != null
          ? DateTime.tryParse(json['concertDate'] as String)
          : null,
      isFavoritedConcert: json['isFavoritedConcert'] as bool? ?? false,
      periodText: json['periodText'] as String?,
      ticketingText: json['ticketingText'] as String?,
      concertEndDate: json['concertEndDate'] != null
          ? DateTime.tryParse(json['concertEndDate'] as String)
          : null,
      ticketingDate: json['ticketingDate'] != null
          ? DateTime.tryParse(json['ticketingDate'] as String)
          : null,
    );
  }

  /// 티케팅(예매) 오픈일까지 남은 일수. 크롤러가 아직 수집 못 한 공연은
  /// 값이 없어 "미정"으로 표시됩니다.
  static String _ticketingDDay(DateTime? date) {
    if (date == null) return '미정';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = target.difference(today).inDays;
    if (diff > 0) return 'D-$diff';
    if (diff == 0) return 'D-DAY';
    return '예매 중';
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
