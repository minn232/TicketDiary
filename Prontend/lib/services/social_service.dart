import '../models/news_model.dart';
import 'api_client.dart';

/// 소식(뉴스 피드)/팔로우 관련 백엔드 연동 서비스(`/social/...`).
///
/// 백엔드 피드는 "서버에 저장된" 아티스트 팔로우 목록(`ArtistFollow`) 기준으로
/// 생성되므로, 피드를 조회하기 전에 로컬 찜 목록([FavoritesStore])을
/// [syncArtistFollows]로 서버에 올려둬야 소식이 만들어질 수 있습니다.
///
/// NOTE: 찜 "공연" 동기화(`PATCH /social/concerts`)는 아직 하지 않습니다.
/// 백엔드가 공연 UUID(`concert_id`)를 요구하는데 로컬 찜 공연 목록은 이름만
/// 갖고 있고, 피드 생성 로직(kopis.py `_create_news_feeds_for_concert`)도
/// 아티스트 팔로우만 사용하기 때문입니다.
class SocialService {
  SocialService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  /// 뉴스 피드 조회(`GET /social/feed`).
  Future<List<NewsModel>> getNewsFeed() async {
    final list = await _client.getList('/social/feed');
    return [
      for (final item in list)
        NewsModel.fromFeedJson(item as Map<String, dynamic>),
    ];
  }

  /// 피드 읽음 처리(`PATCH /social/feed/{feedId}/read`).
  Future<void> markFeedRead(String feedId) async {
    await _client.patch('/social/feed/$feedId/read');
  }

  /// 서버에 저장된 팔로우 아티스트 항목들을 그대로 가져옵니다
  /// (`GET /social/artists`). 각 항목은 `artist_name`(+ 있으면
  /// `kopis_artist_id`)을 담은 JSON입니다.
  Future<List<Map<String, dynamic>>> getArtistFollowEntries() async {
    final json = await _client.get('/social/artists');
    final artists = json['artists'] as List<dynamic>? ?? const [];
    return [
      for (final a in artists) (a as Map).cast<String, dynamic>(),
    ];
  }

  /// 서버 팔로우 아티스트 목록을 [artistNames]로 통째로 교체합니다
  /// (`PATCH /social/artists`). 찜 설정 화면처럼 사용자가 목록 전체를
  /// 직접 관리하는 곳에서 사용합니다(해제도 서버에 반영됨).
  Future<void> replaceArtistFollows(List<String> artistNames) async {
    await _client.patch(
      '/social/artists',
      body: {
        'artists': [
          for (final name in artistNames) {'artist_name': name},
        ],
      },
    );
  }

  /// 서버에 저장된 찜 공연 항목들을 가져옵니다(`GET /social/concerts`).
  /// 각 항목은 `concert_id`(+ 있으면 `kopis_concert_id`)를 담은 JSON입니다.
  Future<List<Map<String, dynamic>>> getConcertFollowEntries() async {
    final json = await _client.get('/social/concerts');
    final concerts = json['concerts'] as List<dynamic>? ?? const [];
    return [
      for (final c in concerts) (c as Map).cast<String, dynamic>(),
    ];
  }

  /// 서버 찜 공연 목록을 통째로 교체합니다(`PATCH /social/concerts`).
  /// [entries]의 각 항목은 `{'concert_id': ..., 'kopis_concert_id': ...}` 형태.
  Future<void> replaceConcertFollows(
    List<Map<String, dynamic>> entries,
  ) async {
    await _client.patch('/social/concerts', body: {'concerts': entries});
  }

  /// 로컬 선호 아티스트를 서버 팔로우 목록에 "추가" 동기화합니다.
  ///
  /// `PATCH /social/artists`는 전체 교체 API라서 로컬 목록을 그대로 보내면
  /// 다른 기기에서 등록해둔 팔로우가 통째로 지워질 수 있습니다. 그래서 먼저
  /// 서버 목록을 읽어와 로컬 목록과 합친 뒤(기존 항목은 kopis_artist_id까지
  /// 그대로 보존), 새로 추가할 이름이 있을 때만 교체 요청을 보냅니다.
  /// 대신 로컬에서 찜을 해제해도 서버에서는 지워지지 않는데, 멀티 기기
  /// 사용 시의 유실 위험보다 안전한 쪽을 택한 것입니다.
  Future<void> syncArtistFollows(List<String> artistNames) async {
    final entries = await getArtistFollowEntries();
    final existingNames = {
      for (final e in entries) e['artist_name'] as String,
    };
    final newNames = [
      for (final name in artistNames)
        if (!existingNames.contains(name)) name,
    ];
    if (newNames.isEmpty) return;

    await _client.patch(
      '/social/artists',
      body: {
        'artists': [
          ...entries,
          for (final name in newNames) {'artist_name': name},
        ],
      },
    );
  }
}
