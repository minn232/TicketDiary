import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 셋리스트 곡 하나를 검색해볼 음악 서비스. 지금은 검색화면만 열어주는
/// 수준(원탭 직결 X) - 로마자/번역 표기는 의외로 잘 맞지만 커버곡·비공식
/// 발매곡은 서비스가 헛돌 수 있어서, 사용자가 검색결과를 직접 보고 확인할 수
/// 있게 하기 위함(자동재생/자동선택 금지).
enum MusicService {
  spotify,
  youtube,
  appleMusic;

  String get label => switch (this) {
        MusicService.spotify => '스포티파이',
        MusicService.youtube => '유튜브',
        MusicService.appleMusic => '애플뮤직',
      };

  // TODO: 예매처(vendorTicketingInfo)처럼 실제 브랜드 로고 이미지로 교체할 것.
  // 지금은 별도 에셋 없이 구분 가능한 Material 아이콘+브랜드색으로 대체.
  IconData get icon => switch (this) {
        MusicService.spotify => Icons.graphic_eq,
        MusicService.youtube => Icons.smart_display,
        MusicService.appleMusic => Icons.apple,
      };

  Color get color => switch (this) {
        MusicService.spotify => const Color(0xFF1DB954),
        MusicService.youtube => const Color(0xFFFF0000),
        MusicService.appleMusic => const Color(0xFFFA243C),
      };

  /// 설정 저장용 문자열 키.
  String get prefsName => switch (this) {
        MusicService.spotify => 'spotify',
        MusicService.youtube => 'youtube',
        MusicService.appleMusic => 'apple_music',
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
      case MusicService.spotify:
        return Uri.parse(
          'https://open.spotify.com/search/${Uri.encodeComponent(query)}',
        );
      case MusicService.youtube:
        return Uri.https('www.youtube.com', '/results', {
          'search_query': query,
        });
      case MusicService.appleMusic:
        // 스토어프론트를 kr로 고정 - 한국 아티스트/유저 기준 앱이라 국가코드
        // 안 맞으면 검색이 잘 안 잡힐 수 있음(실측 필요, 일단 kr로 시작).
        return Uri.https('music.apple.com', '/kr/search', {'term': query});
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
