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

  const ConcertModel({
    required this.name,
    required this.posterImageUrl,
    this.id = '',
    this.kopisId,
  });
}
