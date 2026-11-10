import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/timetable.dart';

TimeTableEntry _e(String? date, String? time, String event) =>
    TimeTableEntry(date: date, time: time, stage: null, event: event);

TimeTableResponse _res(List<TimeTableEntry> c) =>
    TimeTableResponse(id: 'a', concertId: 'b', contents: c);

void main() {
  // 이틀 공연(드래곤포니 12/5~6)을 입력 순서 그대로 섞어 넣은 경우
  final twoDays = _res([
    _e('2026-12-05', '18:00', '공연 시작'),
    _e('2026-12-06', '17:00', '공연 시작'),
    _e('2026-12-05', '15:00', '티켓부스 오픈'),
    _e('2026-12-05', '16:30', '스탠딩 대기'),
    _e('2026-12-06', '15:30', '스탠딩 대기'),
  ]);

  test('관람일 항목만 시간순으로', () {
    final d5 = twoDays.entriesForDay(DateTime(2026, 12, 5));
    expect(d5.map((e) => e.event), ['티켓부스 오픈', '스탠딩 대기', '공연 시작']);
    final d6 = twoDays.entriesForDay(DateTime(2026, 12, 6));
    expect(d6.map((e) => e.time), ['15:30', '17:00']);
  });

  test('날짜 없는 항목은 모든 날에 포함', () {
    final res = _res([
      _e('2026-12-05', '18:00', 'A'),
      _e('2026-12-06', '17:00', 'B'),
      _e(null, '09:00', '공통'),
    ]);
    expect(res.entriesForDay(DateTime(2026, 12, 6)).map((e) => e.event), [
      '공통',
      'B',
    ]);
  });

  test('날짜가 하나뿐이면 거르지 않음', () {
    final res = _res([
      _e('2023-09-07', '18:00', 'A'),
      _e('2023-09-07', '19:00', 'B'),
    ]);
    expect(res.entriesForDay(DateTime(2026, 12, 6)).length, 2);
  });

  test('시간이 하나라도 비면 입력 순서 유지, 날짜 모르면 전부', () {
    final res = _res([
      _e('2026-12-05', '18:00', 'A'),
      _e('2026-12-05', null, 'B 17:00'),
      _e('2026-12-06', '10:00', 'C'),
    ]);
    expect(res.entriesForDay(DateTime(2026, 12, 5)).map((e) => e.event), [
      'A',
      'B 17:00',
    ]);
    expect(res.entriesForDay(null).length, 3);
  });
}
