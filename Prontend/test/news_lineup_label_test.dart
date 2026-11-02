import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/models/ticket_scan.dart' show TicketingPhaseEntry;

// [백엔드 수정] 찜한 공연 카드 윗줄(출연진) 규칙.
void main() {
  test('출연진이 없으면 라인업 발표 전', () {
    expect(NewsModel.lineupLabel([], const []), ('라인업 발표 전', null));
    expect(NewsModel.lineupLabel([' '], const []), ('라인업 발표 전', null));
  });

  test('1팀은 이름, 2팀은 쉼표로, 3팀 이상은 외 N팀', () {
    expect(NewsModel.lineupLabel(['넬'], const []), ('넬', null));
    expect(NewsModel.lineupLabel(['넬', '자우림'], const []), ('넬, 자우림', null));
    expect(NewsModel.lineupLabel(['잔나비', '넬', '자우림', '넬'], const []), (
      '잔나비',
      ' 외 2팀',
    ));
  });

  test('팔로우한 아티스트가 맨 앞으로', () {
    expect(NewsModel.lineupLabel(['잔나비', '넬', '자우림'], ['자우림']), (
      '자우림',
      ' 외 2팀',
    ));
    expect(NewsModel.lineupLabel(['넬', '자우림'], ['자우림']), ('자우림, 넬', null));
  });

  test('괄호 표기·대소문자·공백이 달라도 같은 아티스트로 봄', () {
    expect(NewsModel.lineupLabel(['잔나비', '데이식스 (DAY6)', '넬'], ['day6']), (
      '데이식스 (DAY6)',
      ' 외 2팀',
    ));
    expect(NewsModel.lineupLabel(['잔나비', 'DAY6', '넬'], ['데이식스 (DAY6)']), (
      'DAY6',
      ' 외 2팀',
    ));
  });

  // 아티스트 소식 피드 카드 - 매칭된 아티스트가 맨 앞, 출연진이 없으면 이름 하나
  Map<String, dynamic> feed(String artist, List<String>? lineup) => {
    'id': 'f',
    'concert_id': 'c',
    'artist_name': artist,
    'is_read': false,
    'concert': {'name': '페스티벌', 'artist_name': ?lineup},
  };

  test('피드 카드는 매칭된 아티스트 외 N팀', () {
    final m = NewsModel.fromFeedJson(feed('넬', ['잔나비', '넬', '자우림']));
    expect((m.artist, m.artistSuffix, m.matchedArtist), ('넬', ' 외 2팀', '넬'));
  });

  test('피드에 출연진이 없으면(옛 서버) 이름 하나', () {
    final m = NewsModel.fromFeedJson(feed('넬', null));
    expect((m.artist, m.artistSuffix), ('넬', null));
  });

  test('출연진 표기가 달라도 매칭된 아티스트를 두 번 세지 않음', () {
    final m = NewsModel.fromFeedJson(feed('IU', ['잔나비', '아이유 (IU)', '넬']));
    expect((m.artist, m.artistSuffix), ('아이유 (IU)', ' 외 2팀'));
    final n = NewsModel.fromFeedJson(feed('아이유', ['잔나비', '넬']));
    expect((n.artist, n.artistSuffix), ('아이유', ' 외 2팀'));
  });

  test('2팀이면 앞 아티스트(팔로우 우선)를 따로 둠 - 카드에서 넘치면 "A 외 1팀"', () {
    final m = NewsModel.fromFeedJson(feed('김윤아', ['자우림', '김윤아']));
    expect((m.artist, m.leadArtist), ('김윤아, 자우림', '김윤아'));
    final one = NewsModel.fromFeedJson(feed('넬', ['넬']));
    expect(one.leadArtist, isNull);
  });

  group('카드 예매 요약', () {
    final today = DateTime.now();
    DateTime day(int offset) =>
        DateTime(today.year, today.month, today.day + offset);

    test('예매 단계가 있으면 다음 단계 이름과 D-day', () {
      final phases = [
        TicketingPhaseEntry(phase: '팬클럽 선예매', date: day(-3)),
        TicketingPhaseEntry(phase: '일반 예매', date: day(5)),
      ];
      expect(NewsModel.ticketingSummary(null, phases), '일반 예매 D-5');
    });

    test('단계가 없으면 예매일 기준', () {
      expect(NewsModel.ticketingSummary(day(22), null), '예매 D-22');
      expect(NewsModel.ticketingSummary(day(0), null), '예매 오늘');
      expect(NewsModel.ticketingSummary(day(-1), null), '예매 중');
      expect(NewsModel.ticketingSummary(null, null), '예매일 미정');
    });

    test('다음 단계 날짜가 미정이면 그 단계 이름으로', () {
      expect(
        NewsModel.ticketingSummary(null, [
          const TicketingPhaseEntry(phase: '2차 예매'),
        ]),
        '2차 예매 날짜 미정',
      );
    });
  });

  test('아티스트 소식 카드 요약은 고정 문구 대신 예매 정보 + 공연 날짜', () {
    final m = NewsModel.fromFeedJson({
      'id': 'f',
      'concert_id': 'c',
      'artist_name': '넬',
      'is_read': false,
      'concert': {
        'name': '공연',
        'start_date': '2026-12-19T00:00:00',
        'end_date': '2026-12-19T00:00:00',
      },
    });
    expect(m.description, '예매일 미정\n2026.12.19');
  });
}
