import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/artist_model.dart';
import 'package:ticketdiary/models/concert_model.dart';
import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/models/ticket_scan.dart';

NewsModel feed(Map<String, dynamic> concert) => NewsModel.fromFeedJson({
  'id': 'feed-1',
  'concert_id': 'concert-1',
  'artist_name': '넬',
  'is_read': false,
  'concert': {'name': '공연', ...concert},
});

ArtistModel artist(String name, [String image = '']) =>
    ArtistModel(name: name, profileImageUrl: image);

void main() {
  group('피드 기본값과 날짜 파싱', () {
    test('공연 객체가 누락되어도 기본 카드로 생성된다', () {
      final model = NewsModel.fromFeedJson({});
      expect(model.artist, '알 수 없는 아티스트');
      expect(model.concert, '알 수 없는 공연');
      expect(model.imageUrl, isEmpty);
      expect(model.isRead, isTrue);
      expect(model.id, isNull);
      expect(model.concertDate, isNull);
      expect(model.periodText, isNull);
      expect(model.ticketingText, '미정');
    });

    for (final invalid in <String?>[null, '', 'not-a-date']) {
      test('날짜가 $invalid 이면 날짜 없이 표시한다', () {
        final model = feed({
          'start_date': invalid,
          'end_date': invalid,
          'ticketing_date': invalid,
        });
        expect(model.concertDate, isNull);
        expect(model.concertEndDate, isNull);
        expect(model.ticketingDate, isNull);
        expect(model.periodText, isNull);
        expect(model.description, '예매일 미정');
      });
    }

    final periods = <(String?, String?, String?)>[
      ('2028-02-29', null, '2028.02.29'),
      ('2028-02-29T09:00:00', '2028-02-29T23:59:00', '2028.02.29'),
      ('2028-02-29', '2028-03-01', '2028.02.29 ~ 2028.03.01'),
      ('2027-12-31', '2028-01-01', '2027.12.31 ~ 2028.01.01'),
      ('2028-02-29', 'invalid', '2028.02.29'),
      (null, '2028-03-01', null),
    ];
    for (final (start, end, expected) in periods) {
      test('공연 기간 $start ~ $end', () {
        final model = feed({'start_date': start, 'end_date': end});
        expect(model.periodText, expected);
        expect(model.concertDate, DateTime.tryParse(start ?? ''));
        expect(model.concertEndDate, DateTime.tryParse(end ?? ''));
        final favorite = NewsModel.fromFavoritedConcert(
          ConcertModel(
            name: '공연',
            posterImageUrl: '',
            startDate: DateTime.tryParse(start ?? ''),
            endDate: DateTime.tryParse(end ?? ''),
          ),
        );
        expect(favorite.periodText, expected);
      });
    }

    test('UTC 일시와 예매처 링크, 읽음 상태를 유지한다', () {
      final model = feed({
        'start_date': '2028-03-01T23:30:00Z',
        'ticketing_date': '2028-02-01T18:00:00Z',
        'ticketing_links': {'YES24': 'https://example.com/ticket'},
      });
      expect(model.concertDate, DateTime.utc(2028, 3, 1, 23, 30));
      expect(model.concertDate!.isUtc, isTrue);
      expect(model.ticketingDate, DateTime.utc(2028, 2, 1, 18));
      expect(model.periodText, '2028.03.01');
      expect(model.ticketingLinks, {'YES24': 'https://example.com/ticket'});
      expect(model.id, 'feed-1');
      expect(model.concertId, 'concert-1');
      expect(model.isRead, isFalse);
    });

    test('공백뿐인 출연진과 문자열이 아닌 출연진은 카드 이름을 망가뜨리지 않는다', () {
      final model = feed({
        'artist_name': [null, 1, ' ', ''],
      });
      expect(model.artist, '넬');
      expect(model.lineup, isEmpty);
      expect(model.artistSuffix, isNull);
      expect(model.leadArtist, isNull);
    });

    test('찜한 공연은 피드 ID가 없고 읽음 상태이며 빈 공연 ID는 null이다', () {
      final model = NewsModel.fromFavoritedConcert(
        const ConcertModel(name: '공연', posterImageUrl: ''),
      );
      expect(model.id, isNull);
      expect(model.concertId, isNull);
      expect(model.isRead, isTrue);
      expect(model.isFavoritedConcert, isTrue);
    });
  });

  group('출연진 정렬과 프로필 매칭', () {
    test('팔로우 그룹과 나머지 그룹의 원래 순서를 유지하고 원본을 바꾸지 않는다', () {
      final lineup = [' A ', 'B', '', 'C', 'A', 'D', 'B'];
      final original = [...lineup];
      expect(NewsModel.orderLineup(lineup, ['D', 'B']), ['B', 'D', 'A', 'C']);
      expect(lineup, original);
    });

    test('이름 일부가 같다는 이유로 다른 아티스트를 매칭하지 않는다', () {
      expect(NewsModel.isFollowedArtist('IU band', ['IU']), isFalse);
      expect(NewsModel.isFollowedArtist(' ', ['']), isFalse);
      expect(NewsModel.isFollowedArtist('아이유 (IU)', [' iu ']), isTrue);
    });

    test('라인업·대표 아티스트·관련 피드를 합치고 찜 목록 순서와 사진을 유지한다', () {
      final model = feed({
        'artist_name': ['넬', '데이식스 (DAY6)'],
      });
      final favorites = [artist('DAY6', 'day6.png'), artist('넬'), artist('IU')];
      model.matchFavorites(favorites, related: ['아이유 (IU)']);
      expect(model.matchedArtists, favorites);
      expect(model.matchedArtists.first.profileImageUrl, 'day6.png');
    });

    test('빈 이름과 중복 프로필은 제외하고 최초 프로필을 유지한다', () {
      final model = feed({
        'artist_name': ['DAY6'],
      });
      final first = artist('day6', 'first.png');
      model.matchFavorites([artist(''), first, artist(' DAY6 ', 'second.png')]);
      expect(model.matchedArtists, [first]);
    });

    test('찜 해제 후 다시 매칭하면 이전 프로필을 제거한다', () {
      final model = feed({});
      model.matchFavorites([artist('넬')]);
      expect(model.matchedArtists, hasLength(1));
      model.matchFavorites([]);
      expect(model.matchedArtists, isEmpty);
    });

    test('출연진 요약 문자열 자체는 아티스트 이름으로 매칭하지 않는다', () {
      final model = NewsModel(
        artist: '넬 외 2팀',
        concert: '',
        imageUrl: '',
        description: '',
      );
      model.matchFavorites([artist('넬 외 2팀'), artist('넬')]);
      expect(model.matchedArtists, isEmpty);
    });
  });

  group('공연 D-day와 예매 단계', () {
    DateTime day(int offset, [int hour = 0]) {
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day + offset, hour);
    }

    for (final (offset, label) in [(-3, 'D+3'), (0, 'D-DAY'), (3, 'D-3')]) {
      test('$offset 일 공연은 시간에 무관하게 $label 표시', () {
        for (final hour in [0, 23]) {
          expect(
            feed({
              'start_date': day(offset, hour).toIso8601String(),
            }).concertDDayLabel,
            label,
          );
        }
      });
    }
    test('공연일을 모르면 D-day는 미정이다', () {
      expect(feed({}).concertDDayLabel, '미정');
    });
    test('예매 단계가 없으면 null을 반환한다', () {
      expect(NewsModel.nextTicketingPhase(null), isNull);
      expect(NewsModel.nextTicketingPhase([]), isNull);
    });
    test('오늘 예매는 시간이 지났더라도 오늘 단계로 남는다', () {
      final today = TicketingPhaseEntry(phase: '일반 예매', date: day(0));
      final phases = [TicketingPhaseEntry(phase: '선예매', date: day(-3)), today];
      expect(NewsModel.nextTicketingPhase(phases), same(today));
      expect(NewsModel.ticketingSummary(null, phases), '일반 예매 오늘');
    });
    test('모든 단계가 지났으면 마지막 단계와 예매 중을 반환한다', () {
      final last = TicketingPhaseEntry(phase: '2차 예매', date: day(-2));
      final phases = [TicketingPhaseEntry(phase: '1차 예매', date: day(-3)), last];
      expect(NewsModel.nextTicketingPhase(phases), same(last));
      expect(NewsModel.ticketingSummary(day(3), phases), '예매 중');
    });
    test('날짜 미정 단계는 공연의 기본 예매일로 대체하지 않는다', () {
      const unknown = TicketingPhaseEntry(phase: '추가 예매');
      final phases = [
        unknown,
        TicketingPhaseEntry(phase: '일반 예매', date: day(3)),
      ];
      expect(NewsModel.nextTicketingPhase(phases), same(unknown));
      expect(NewsModel.ticketingSummary(day(2), phases), '추가 예매 날짜 미정');
    });
  });

  group('캐시 직렬화', () {
    test('빈 구버전 캐시는 기본값으로 복원된다', () {
      final model = NewsModel.fromCacheJson({});
      expect(model.isRead, isTrue);
      expect(model.isFavoritedConcert, isFalse);
      expect(model.lineup, isEmpty);
      expect(model.matchedArtists, isEmpty);
      expect(model.concertDate, isNull);
      expect(model.ticketingPhases, isNull);
    });
    test('유효하지 않은 캐시 날짜는 null로 복원된다', () {
      final model = NewsModel.fromCacheJson({
        'concertDate': '',
        'concertEndDate': 'invalid',
        'ticketingDate': 'invalid',
      });
      expect(model.concertDate, isNull);
      expect(model.concertEndDate, isNull);
      expect(model.ticketingDate, isNull);
    });
    test('실제 JSON 인코딩 왕복 후 모든 화면 정보와 수정한 읽음 상태가 보존된다', () {
      final model = feed({
        'artist_name': ['넬', 'DAY6', 'IU'],
        'poster_url': 'https://example.com/poster.png',
        'venue': '공연장',
        'start_date': '2028-03-01T19:00:00Z',
        'end_date': '2028-03-02T20:00:00Z',
        'ticketing_date': '2028-01-01T18:00:00Z',
        'ticketing_links': {'YES24': 'https://example.com/ticket'},
        'ticketing_phases': [
          {'phase': '선예매', 'date': '2028-01-01'},
          {'phase': '일반 예매', 'date': null},
        ],
      });
      model.matchFavorites([artist('넬', 'profile.png'), artist('IU')]);
      model.isRead = true;
      final json =
          jsonDecode(jsonEncode(model.toJson())) as Map<String, dynamic>;
      final restored = NewsModel.fromCacheJson(json);
      expect(restored.toJson(), json);
      expect(restored.matchedArtists.map((a) => a.name), ['넬', 'IU']);
      expect(restored.matchedArtists.first.profileImageUrl, 'profile.png');
      expect(restored.ticketingPhases!.last.date, isNull);
      expect(restored.concertDate!.isUtc, isTrue);
      expect(restored.isRead, isTrue);
    });
  });
}
