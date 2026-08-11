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

  // [백엔드 수정]
  // /concerts/{concertId}/setlist/pre → /tickets/{ticketId}/setlist/pre.
  // concertId만으로는 페스티벌처럼 날짜가 여러 개인 공연에서 어느 날짜인지 특정이 안 돼 400.
  // 티켓 기준 라우트는 ticket.attended_date로 내부에서 날짜를 자동으로 잡아줌.
  // 게스트도 이제 서버 ticketId를 갖게 돼서(TicketService 참고), 예전에
  // 있던 concertId 기준 게스트 전용 폴백(getPreSetlistByConcert)은 제거.
  /// 예상 셋리스트 조회(`GET /tickets/{ticketId}/setlist/pre`).
  Future<PreSetlistResponse> getPreSetlist(String ticketId) async {
    final json = await _client.get('/tickets/$ticketId/setlist/pre');
    return PreSetlistResponse.fromJson(json);
  }

  // [백엔드 수정]
  // /concerts/{concertId}/setlist → /tickets/{ticketId}/setlist.
  // 위 예상 셋리스트와 같은 이유(다중 날짜 400 회피). 게스트 전용 폴백
  // (getRealSetlistByConcert)도 같은 이유로 제거.
  /// 실제 셋리스트 조회(`GET /tickets/{ticketId}/setlist`).
  Future<RealSetlistResponse> getRealSetlist(String ticketId) async {
    final json = await _client.get('/tickets/$ticketId/setlist');
    return RealSetlistResponse.fromJson(json);
  }
}
