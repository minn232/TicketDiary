import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 셋리스트 곡 하나를 연결해볼 음악 서비스. 원탭 직결(정확한 트랙/영상)을
/// 먼저 시도하고([MusicLinkResolveService]), 못 찾으면(커버곡·비공식 발매곡
/// 등) 여기 [buildSearchUri]로 검색화면을 열어 사용자가 직접 확인하게
/// 폴백함(자동재생/자동선택 금지).
// [백엔드 수정] 아이콘 노출 순서 요청으로 유튜브/유튜브뮤직/애플뮤직/스포티파이로 재정렬.
enum MusicService {
  youtube,
  // 유튜브와 카탈로그(영상 ID)는 같지만 앱이 달라서 따로 둠 - 유튜브는 "그 무대 영상/직캠
  // 보기", 유튜브뮤직은 "음악만 바로 듣기" 용도로 구분해서 쓰라는 요청 반영.
  youtubeMusic,
  appleMusic,
  spotify;

  String get label => switch (this) {
        MusicService.youtube => '유튜브',
        MusicService.youtubeMusic => '유튜브뮤직',
        MusicService.appleMusic => '애플뮤직',
        MusicService.spotify => '스포티파이',
      };

  // 예매처(vendorTicketingInfo)와 동일하게 각 서비스 공식 앱 아이콘(App Store 아트워크
  // 원본) 에셋 사용 - Material 아이콘 대체물이라 헷갈린다는 피드백으로 교체함.
  String get iconAsset => switch (this) {
        MusicService.youtube => 'assets/images/streaming/youtube.jpg',
        MusicService.youtubeMusic => 'assets/images/streaming/youtube_music.jpg',
        MusicService.appleMusic => 'assets/images/streaming/apple_music.jpg',
        MusicService.spotify => 'assets/images/streaming/spotify.jpg',
      };

  // 설정탭 선택 표시 테두리/배경 등 - 아이콘 자체는 이미 실제 브랜드색을 담고 있어서 더 이상
  // 틴트하는 데는 안 씀.
  Color get color => switch (this) {
        MusicService.youtube => const Color(0xFFFF0000),
        MusicService.youtubeMusic => const Color(0xFFFF0000),
        MusicService.appleMusic => const Color(0xFFFA243C),
        MusicService.spotify => const Color(0xFF1DB954),
      };

  /// 설정 저장용 문자열 키.
  String get prefsName => switch (this) {
        MusicService.youtube => 'youtube',
        MusicService.youtubeMusic => 'youtube_music',
        MusicService.appleMusic => 'apple_music',
        MusicService.spotify => 'spotify',
      };

  static MusicService fromPrefsName(String? name) {
    for (final service in MusicService.values) {
      if (service.prefsName == name) return service;
    }
    return MusicService.spotify;
  }

  /// [query](아티스트+곡명)를 이 서비스의 검색화면 URL로 변환.
  /// 전부 https 유니버설링크라 앱이 깔려있으면 앱으로, 없으면 자동으로
  /// 웹으로 폴백됨(예매처 커스텀 스킴과 달리 별도 폴백 처리가 필요 없음).
  Uri buildSearchUri(String query) {
    switch (this) {
      case MusicService.youtube:
        return Uri.https('www.youtube.com', '/results', {
          'search_query': query,
        });
      case MusicService.youtubeMusic:
        return Uri.https('music.youtube.com', '/search', {'q': query});
      case MusicService.appleMusic:
        // 스토어프론트를 kr로 고정 - 한국 아티스트/유저 기준 앱이라 국가코드
        // 안 맞으면 검색이 잘 안 잡힐 수 있음(실측 필요, 일단 kr로 시작).
        return Uri.https('music.apple.com', '/kr/search', {'term': query});
      case MusicService.spotify:
        return Uri.parse(
          'https://open.spotify.com/search/${Uri.encodeComponent(query)}',
        );
    }
  }
}

/// [artist]+[song]으로 [service] 검색화면을 엽니다. artist가 없으면 곡명만으로
/// 검색(단독 공연에서 아티스트 태그가 비어있는 옛날 데이터 등).
Future<void> openMusicSearch(
  MusicService service, {
  String? artist,
  required String song,
}) async {
  final query = [
    if (artist != null && artist.trim().isNotEmpty) artist.trim(),
    song.trim(),
  ].join(' ').trim();
  if (query.isEmpty) return;

  try {
    await launchUrl(
      service.buildSearchUri(query),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    // 앱/브라우저를 못 열어도(설치 안 됨 등) 조용히 무시 - 곡 링크 하나 실패로
    // 화면 전체에 에러를 띄울 정도는 아님.
  }
}
