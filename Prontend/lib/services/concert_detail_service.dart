import '../models/setlist.dart';
import '../models/timetable.dart';
import 'api_client.dart';

/// 공연 상세(타임테이블/셋리스트) 조회 서비스.
/// 전부 `/concerts/{concertId}/...` 하위 엔드포인트(조회는 읽기 전용).
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
    final json = await _client.get('/concerts/$concertId/setlist/pre');
    return PreSetlistResponse.fromJson(json);
  }

  /// 실제 셋리스트 조회(`GET /concerts/{concertId}/setlist`).
  Future<RealSetlistResponse> getRealSetlist(String concertId) async {
    final json = await _client.get('/concerts/$concertId/setlist');
    return RealSetlistResponse.fromJson(json);
  }
}
