import 'api_client.dart';
import 'music_service_links.dart';

/// 셋리스트 곡을 실제 트랙/영상으로 원탭 연결하기 위한 백엔드 리졸브 호출
/// (`GET /music-links/resolve`, `music_resolve.py` 참고).
///
/// 서버가 아티스트/곡명 둘 다 확실히 일치하는 결과를 못 찾으면(비공식 발매곡,
/// API 키 미설정 등) null을 반환하고, 이 서비스도 예외 없이 null로 통일해서
/// 돌려줍니다 - 호출부는 null이면 검색화면 폴백으로 넘어가면 됩니다.
class MusicLinkResolveService {
  MusicLinkResolveService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  Future<Uri?> resolve(MusicService service, {String? artist, required String song}) async {
    final params = <String, String>{
      'service': service.prefsName,
      'song': song,
      if (artist != null && artist.trim().isNotEmpty) 'artist': artist,
    };
    final query = params.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    try {
      final json = await _client.get('/music-links/resolve?$query');
      final url = json['url'] as String?;
      return url == null ? null : Uri.tryParse(url);
    } catch (_) {
      // 네트워크/서버 오류 - 검색화면 폴백으로 조용히 넘어감(곡 링크 하나 실패로
      // 화면 전체에 에러를 띄울 정도는 아님, music_service_links.dart의
      // openMusicSearch와 같은 방침).
      return null;
    }
  }
}
