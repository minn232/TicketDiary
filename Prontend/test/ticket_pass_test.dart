import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/ticket_pass.dart';

void main() {
  group('passDaysFromText', () {
    test('권종 표기에서 관람 일수를 읽음', () {
      expect(passDaysFromText('2일권 스탠딩'), 2);
      expect(passDaysFromText('양일권(얼리버드)'), 2);
      expect(passDaysFromText('3-DAYS PASS'), 3);
      expect(passDaysFromText('블라인드티켓3일권'), 3);
      expect(passDaysFromText('전일권'), passAllDays);
    });

    test('하루짜리·회차 번호·권종이 섞인 글자는 null', () {
      expect(passDaysFromText('1일권(토)'), isNull);
      expect(passDaysFromText('일일권(일요일)'), isNull);
      expect(passDaysFromText('DAY2 입장'), isNull);
      expect(passDaysFromText('1일권 99,000원 / 2일권 180,000원'), isNull);
      expect(passDaysFromText('R석'), isNull);
      expect(passDaysFromText(null), isNull);
    });
  });

  group('passDayCombos', () {
    final fri = DateTime(2030, 8, 2);
    final sat = DateTime(2030, 8, 3);
    final sun = DateTime(2030, 8, 4);

    test('금토일 중 2일권은 3가지 조합', () {
      expect(passDayCombos([fri, sat, sun], 2), [
        [fri, sat],
        [fri, sun],
        [sat, sun],
      ]);
    });

    test('티켓에 찍힌 날로 시작하는 조합만 남김', () {
      expect(passDayCombos([fri, sat, sun], 2, firstDay: fri), [
        [fri, sat],
        [fri, sun],
      ]);
      expect(passDayCombos([fri, sat, sun], 2, firstDay: sat), [
        [sat, sun],
      ]);
    });

    test('그 날로 시작하는 조합이 없으면 전체', () {
      expect(passDayCombos([fri, sat, sun], 2, firstDay: sun), hasLength(3));
    });

    test('공연 기간보다 길면 빈 목록', () {
      expect(passDayCombos([fri, sat], 3), isEmpty);
    });
  });
}
