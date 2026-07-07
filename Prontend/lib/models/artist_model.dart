/// 아티스트 검색/찜 기능에서 사용하는 모델.
/// 백엔드에서 이름과 프로필 이미지 URL을 조회해 채워줍니다.
class ArtistModel {
  final String name;
  final String profileImageUrl;

  const ArtistModel({required this.name, required this.profileImageUrl});
}
