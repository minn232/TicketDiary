import '../models/preview_track.dart';
import '../models/setlist.dart';
import '../models/timetable.dart';
import 'api_client.dart';

/// 공연 상세(타임테이블/셋리스트) 조회 서비스.
/// 타임테이블은 티켓 기준 라우트가 없어 그대로 `/concerts/{concertId}/timetable`.
/// 셋리스트(실제/예상)는 `/tickets/{ticketId}/...`로 옮김.
class ConcertDetailService {
  ConcertDetailService({ApiClient? client})
    : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  /// 타임테이블 조회(`GET /concerts/{concertId}/timetable`).
  /// 아직 등록 안 됐으면 백엔드가 404를 주므로 [ApiException]이 던져집니다.
  Future<TimeTableResponse> getTimetable(String concertId) async {
    final json = await _client.get('/concerts/$concertId/timetable');
    return TimeTableResponse.fromJson(json);
  }

  // [백엔드 수정]
  // /concerts/{concertId}/setlist/pre → /tickets/{ticketId}/setlist/pre(날짜는 ticket.attended_date로 서버가 잡음).
  // 게스트 전용 폴백(getPreSetlistByConcert) 제거.
  /// 예상 셋리스트 조회(`GET /tickets/{ticketId}/setlist/pre`).
  Future<PreSetlistResponse> getPreSetlist(String ticketId) async {
    final json = await _client.get('/tickets/$ticketId/setlist/pre');
    return PreSetlistResponse.fromJson(json);
  }

  // [백엔드 수정]
  // /concerts/{concertId}/setlist → /tickets/{ticketId}/setlist.
  // 게스트 전용 폴백(getRealSetlistByConcert) 제거.
  /// 실제 셋리스트 조회(`GET /tickets/{ticketId}/setlist`).
  Future<RealSetlistResponse> getRealSetlist(String ticketId) async {
    final json = await _client.get('/tickets/$ticketId/setlist');
    return RealSetlistResponse.fromJson(json);
  }

  // [백엔드 수정] 티켓 미리듣기 후보 곡 조회 추가.
  /// 미리듣기 후보 조회(`GET /tickets/{ticketId}/preview-tracks`).
  /// [quick]이면 아티스트 2팀만 모아 빨리 응답(첫 재생용).
  Future<PreviewTracksResponse> getPreviewTracks(
    String ticketId, {
    bool quick = false,
  }) async {
    final json = await _client.get(
      '/tickets/$ticketId/preview-tracks${quick ? '?quick=true' : ''}',
    );
    return PreviewTracksResponse.fromJson(json);
  }

  // [백엔드 수정]
  // 셋리스트 유저 수정 신규 - PATCH는 곡 배열을 통째로 교체.
  /// 실제 셋리스트 수정(`PATCH /tickets/{ticketId}/setlist`).
  Future<RealSetlistResponse> editRealSetlist(
    String ticketId,
    List<SongEntry> songs,
  ) async {
    final json = await _client.patch(
      '/tickets/$ticketId/setlist',
      body: {'songs': songs.map((s) => s.toJson()).toList()},
    );
    return RealSetlistResponse.fromJson(json);
  }

  /// 예상 셋리스트 수정(`PATCH /tickets/{ticketId}/setlist/pre`).
  Future<PreSetlistResponse> editPreSetlist(
    String ticketId,
    List<SongEntry> songs,
  ) async {
    final json = await _client.patch(
      '/tickets/$ticketId/setlist/pre',
      body: {'songs': songs.map((s) => s.toJson()).toList()},
    );
    return PreSetlistResponse.fromJson(json);
  }

  // [백엔드 수정] 예상 셋리 앵커(아티스트 확정) 신규.
  /// 공연 아티스트 이름으로 후보 검색(`GET /tickets/{ticketId}/setlist/pre/artist-candidates`).
  Future<List<ArtistCandidate>> searchArtistCandidates(
    String ticketId,
    String artist,
  ) async {
    final json = await _client.getList(
      '/tickets/$ticketId/setlist/pre/artist-candidates?artist=${Uri.encodeQueryComponent(artist)}',
    );
    return json
        .map((e) => ArtistCandidate.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 곡 제목으로 앵커 후보 검색(`GET /tickets/{ticketId}/setlist/pre/anchor-candidates`).
  Future<List<ArtistAnchorCandidate>> searchAnchorCandidates(
    String ticketId,
    String song,
  ) async {
    final json = await _client.getList(
      '/tickets/$ticketId/setlist/pre/anchor-candidates?song=${Uri.encodeQueryComponent(song)}',
    );
    return json
        .map((e) => ArtistAnchorCandidate.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 고른 후보의 아티스트로 확정하고 대표곡으로 다시 채운 예상 셋리 반환
  /// (`POST /tickets/{ticketId}/setlist/pre/anchor`).
  Future<PreSetlistResponse> anchorPreSetlistArtist(
    String ticketId, {
    required String artist,
    required String itunesArtistId,
  }) async {
    final json = await _client.post(
      '/tickets/$ticketId/setlist/pre/anchor',
      body: {'artist': artist, 'itunes_artist_id': itunesArtistId},
    );
    return PreSetlistResponse.fromJson(json);
  }

  // [백엔드 수정] 공연별 아티스트 연결 수정 신규.
  /// 연결 수정 후보(`GET /tickets/{ticketId}/artist-identity/candidates`).
  Future<IdentityCandidatesResponse> getIdentityCandidates(
    String ticketId,
    String artist,
  ) async {
    final json = await _client.get(
      '/tickets/$ticketId/artist-identity/candidates?artist=${Uri.encodeQueryComponent(artist)}',
    );
    return IdentityCandidatesResponse.fromJson(json);
  }

  /// 이 공연의 [artist]를 고른 후보(또는 [noArtist]면 "없음")로 연결
  /// (`POST /tickets/{ticketId}/artist-identity`).
  Future<void> changeArtistIdentity(
    String ticketId, {
    required String artist,
    IdentityCandidate? candidate,
    bool noArtist = false,
  }) async {
    await _client.post(
      '/tickets/$ticketId/artist-identity',
      body: {
        'artist': artist,
        if (noArtist)
          'no_artist': true
        else if (candidate?.canonicalId != null)
          'canonical_id': candidate!.canonicalId
        else
          'mbid': candidate?.mbid,
      },
    );
  }
}
