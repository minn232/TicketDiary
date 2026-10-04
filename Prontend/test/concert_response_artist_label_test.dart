import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/ticket_scan.dart';

Map<String, dynamic> _json({List<String>? displayNames}) => {
  'id': 'c1',
  'name': '공연',
  'artist_name': ['Lany', '게스트'],
  'start_date': '2026-10-03T00:00:00+00:00',
  'end_date': '2026-10-03T00:00:00+00:00',
  'event_type': 'solo',
  'artist_display_names': ?displayNames,
};

void main() {
  test('아티스트 연결을 바꾼 공연은 연결된 이름으로 보여준다', () {
    final concert = ConcertResponse.fromJson(
      _json(displayNames: ['LANY', '게스트']),
    );
    expect(concert.artistLabel, 'LANY, 게스트');
    expect(concert.artistName, ['Lany', '게스트']);
  });

  test('표시용 이름이 없으면 원래 이름을 쓴다', () {
    expect(ConcertResponse.fromJson(_json()).artistLabel, 'Lany, 게스트');
  });
}
