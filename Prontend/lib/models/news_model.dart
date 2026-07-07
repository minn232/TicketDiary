/// [준비 1] 소식 데이터 모델 클래스.
/// 백엔드 JSON 데이터 구조가 확정되면 factory NewsModel.fromJson 부분을 수정하면 됩니다.
class NewsModel {
  final String artist;
  final String concert;
  final String imageUrl;

  /// 소식 한 줄 요약(폴라로이드 카드에 노출). 백엔드에서 조회해 채워집니다.
  final String description;

  /// 소식 상세(카드를 눌렀을 때 확장되는 화면)에 보여줄 줄글 형태의 기사 본문.
  /// 백엔드에서 조회해 채워지며, 아직 없으면 빈 문자열로 둡니다.
  final String content;

  /// 소식 상세 화면에서 아티스트 이름과 기사 본문 사이에 들어갈 이미지.
  /// 폴라로이드 카드의 [imageUrl](포스터/썸네일)과는 별개로, 백엔드에서 조회해
  /// 채워집니다. 아직 없으면 빈 문자열로 두면 깨진 이미지 아이콘이 표시됩니다.
  final String articleImageUrl;

  NewsModel({
    required this.artist,
    required this.concert,
    required this.imageUrl,
    required this.description,
    this.content = '',
    this.articleImageUrl = '',
  });

  // 나중에 백엔드 JSON 필드명에 맞춰 여기만 고치면 됩니다.
  factory NewsModel.fromJson(Map<String, dynamic> json) {
    return NewsModel(
      artist: json['artist_name'] ?? 'Unknown Artist',
      concert: json['concert_title'] ?? 'Untitled Concert',
      imageUrl: json['image_url'] ?? '',
      description: json['short_desc'] ?? '',
      content: json['content'] ?? '',
      articleImageUrl: json['article_image_url'] ?? '',
    );
  }
}
