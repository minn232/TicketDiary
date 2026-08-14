/// 공연 검색/찜 기능에서 사용하는 모델.
/// 백엔드 `GET /concerts/search`에서 이름/포스터/식별자를 조회해 채워집니다.
class ConcertModel {
  final String name;
  final String posterImageUrl;

  /// 백엔드 공연 UUID. 찜 목록을 서버(`PATCH /social/concerts`)에 동기화할 때
  /// 필요합니다. 백엔드에서 검색되지 않은 항목(구버전 로컬 저장 등)은 빈 문자열.
  final String id;

  /// KOPIS 공연 ID. 서버에만 있는 찜 공연의 이름/포스터를 되찾을 때
  /// (`GET /concerts/{kopis_id}`) 사용합니다.
  final String? kopisId;

  /// 공연장/공연 기간/출연 아티스트. 소식탭에 찜한 공연 카드를 보여줄 때
  /// 요약·상세 문구를 만드는 데 씁니다. 검색 결과엔 대체로 있지만, 아주
  /// 오래된 로컬 저장 데이터에는 없을 수 있어 nullable/빈 리스트로 둡니다.
  final String? venue;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<String> artistName;

  /// 티케팅(예매) 오픈 일시. KOPIS 목록 검색엔 항상 비어 있고, 크롤러가
  /// 예매처에서 실제로 수집해 백엔드에 채워준 경우에만 값이 옵니다.
  final DateTime? ticketingDate;

  // [백엔드 수정]
  // 예매처 바로가기 버튼용(키: YES24/INTERPARK/TICKETLINK/MELON). KOPIS가
  // 못 준 공연은 null/빈 맵.
  final Map<String, String>? ticketingLinks;

  const ConcertModel({
    required this.name,
    required this.posterImageUrl,
    this.id = '',
    this.kopisId,
    this.venue,
    this.startDate,
    this.endDate,
    this.artistName = const [],
    this.ticketingDate,
    this.ticketingLinks,
  });
}
