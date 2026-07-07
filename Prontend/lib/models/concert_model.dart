/// 공연 검색/찜 기능에서 사용하는 모델.
/// 백엔드에서 공연 이름과 포스터 이미지 URL을 조회해 채워줍니다.
class ConcertModel {
  final String name;
  final String posterImageUrl;

  const ConcertModel({required this.name, required this.posterImageUrl});
}
