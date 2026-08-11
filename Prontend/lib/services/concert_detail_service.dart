import '../models/setlist.dart';
import '../models/timetable.dart';
import 'api_client.dart';

/// 공연 상세(타임테이블/셋리스트) 조회 서비스.
/// 타임테이블은 티켓 기준 라우트가 없어 그대로 `/concerts/{concertId}/timetable`.
/// 셋리스트(실제/예상)는 `/tickets/{ticketId}/...`로 옮김.
class ConcertDetailService {
  ConcertDetailService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  /// 타임테이블 조회(`GET /concerts/{concertId}/timetable`).
  /// 아직 등록 안 됐으면 백엔드가 404를 주므로 [ApiException]이 던져집니다.
  Future<TimeTableResponse> getTimetable(String concertId) async {
    final json = await _client.get('/concerts/$concertId/timetable');
    return TimeTableResponse.fromJson(json);
  }

  /// 예상 셋리스트 조회(`GET /concerts/{concertId}/setlist/pre`).
  /// 유저의 `show_predicted_setlist` 설정이 꺼져있으면 백엔드가 403을 줍니다.
  Future<PreSetlistResponse> getPreSetlist(String concertId) async {
  // [백엔드 수정]
  // /concerts/{concertId}/setlist/pre → /tickets/{ticketId}/setlist/pre.
  // concertId만으로는 페스티벌처럼 날짜가 여러 개인 공연에서 어느 날짜인지 특정이 안 돼 400.
  // 티켓 기준 라우트는 ticket.attended_date로 내부에서 날짜를 자동으로 잡아줌.
  /// 예상 셋리스트 조회(`GET /tickets/{ticketId}/setlist/pre`).
  Future<PreSetlistResponse> getPreSetlist(String ticketId) async {
    final json = await _client.get('/tickets/$ticketId/setlist/pre');
    return PreSetlistResponse.fromJson(json);
  }

  // [백엔드 수정]
  // 게스트 티켓은 서버에 등록되지 않고 로컬 전용 id(예: guest_ticket_123...)만
  // 가지고 있어서, 위 getPreSetlist(ticketId)를 그대로 쓰면 백엔드가 UUID 파싱에 실패해 422.
  // 그 경우를 위한 concertId 기준 폴백(다중 날짜 400 회피는 안 되지만, 최소한 동작은 함) —
  // 호출부(위젯)에서 AuthService.isGuest로 분기해서 사용.
  /// 예상 셋리스트 조회, 게스트 전용 폴백(`GET /concerts/{concertId}/setlist/pre`).
  Future<PreSetlistResponse> getPreSetlistByConcert(String concertId) async {
    final json = await _client.get('/concerts/$concertId/setlist/pre');
    return PreSetlistResponse.fromJson(json);
  }

  // [백엔드 수정]
  // /concerts/{concertId}/setlist → /tickets/{ticketId}/setlist.
  // 위 예상 셋리스트와 같은 이유(다중 날짜 400 회피).
  /// 실제 셋리스트 조회(`GET /tickets/{ticketId}/setlist`).
  Future<RealSetlistResponse> getRealSetlist(String ticketId) async {
    final json = await _client.get('/tickets/$ticketId/setlist');
    return RealSetlistResponse.fromJson(json);
  }

  // [백엔드 수정]
  // getPreSetlistByConcert와 같은 이유의 게스트 전용 폴백.
  /// 실제 셋리스트 조회, 게스트 전용 폴백(`GET /concerts/{concertId}/setlist`).
  Future<RealSetlistResponse> getRealSetlistByConcert(String concertId) async {
    final json = await _client.get('/concerts/$concertId/setlist');
    return RealSetlistResponse.fromJson(json);
  }
}
