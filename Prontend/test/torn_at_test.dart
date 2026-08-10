import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/models/ticket_response.dart';
import 'package:ticketdiary/models/ticket_scan.dart';
import 'package:ticketdiary/services/local_ticket_store.dart';

ConcertResponse buildConcert({String id = 'concert-1'}) {
  return ConcertResponse(
    id: id,
    name: '테스트 공연',
    artistName: const ['아티스트'],
    startDate: DateTime(2020, 1, 1), // 이미 끝난 공연 -> after_concert
    endDate: DateTime(2020, 1, 1),
    eventType: 'concert',
  );
}

void main() {
  group('TicketWithConcert.tornAt', () {
    test('fromJson이 torn_at을 파싱한다', () {
      final ticket = TicketWithConcert.fromJson({
        'id': 't1',
        'status': 'after_concert',
        'torn_at': '2026-08-10T12:00:00.000Z',
      });
      expect(ticket.tornAt, DateTime.parse('2026-08-10T12:00:00.000Z'));
    });

    test('torn_at이 없으면 null이다', () {
      final ticket = TicketWithConcert.fromJson({
        'id': 't1',
        'status': 'after_concert',
      });
      expect(ticket.tornAt, isNull);
    });

    test('toJson이 torn_at을 왕복시킨다', () {
      final now = DateTime.parse('2026-08-10T12:00:00.000Z');
      final ticket = TicketWithConcert(id: 't1', status: 'after_concert', tornAt: now);
      final json = ticket.toJson();
      expect(json['torn_at'], now.toIso8601String());

      final restored = TicketWithConcert.fromJson(json);
      expect(restored.tornAt, now);
    });

    test('copyWith: tornAt을 안 넘기면 기존 값을 유지한다', () {
      final now = DateTime.parse('2026-08-10T12:00:00.000Z');
      final ticket = TicketWithConcert(id: 't1', status: 'after_concert', tornAt: now);
      final updated = ticket.copyWith(status: 'after_concert');
      expect(updated.tornAt, now);
    });

    test('copyWith: tornAt에 값을 넘기면 그 값으로 바뀐다', () {
      final ticket = TicketWithConcert(id: 't1', status: 'after_concert');
      final now = DateTime.parse('2026-08-10T12:00:00.000Z');
      final updated = ticket.copyWith(tornAt: now);
      expect(updated.tornAt, now);
    });

    test('copyWith: tornAt에 명시적으로 null을 넘기면 지워진다', () {
      final now = DateTime.parse('2026-08-10T12:00:00.000Z');
      final ticket = TicketWithConcert(id: 't1', status: 'after_concert', tornAt: now);
      final updated = ticket.copyWith(tornAt: null);
      expect(updated.tornAt, isNull);
    });
  });

  group('LocalTicketStore(게스트) torn_at', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('tornAt을 설정하면 저장되고, 다시 불러와도 유지된다', () async {
      final concert = buildConcert();
      final created = await LocalTicketStore.instance.createTicket(concert: concert);
      expect(created.tornAt, isNull);

      final now = DateTime.parse('2026-08-10T12:00:00.000Z');
      final updated = await LocalTicketStore.instance.updateTicket(
        created.id,
        tornAt: now,
      );
      expect(updated.tornAt, now);

      final list = await LocalTicketStore.instance.listTickets();
      expect(list.single.tornAt, now);
    });

    test('clearTornAt: true면 null로 되돌아간다', () async {
      final concert = buildConcert(id: 'concert-2');
      final created = await LocalTicketStore.instance.createTicket(concert: concert);
      final now = DateTime.parse('2026-08-10T12:00:00.000Z');
      await LocalTicketStore.instance.updateTicket(created.id, tornAt: now);

      final reset = await LocalTicketStore.instance.updateTicket(
        created.id,
        clearTornAt: true,
      );
      expect(reset.tornAt, isNull);

      final list = await LocalTicketStore.instance.listTickets();
      expect(list.single.tornAt, isNull);
    });

    test('tornAt/clearTornAt 둘 다 안 주면 기존 값을 그대로 유지한다', () async {
      final concert = buildConcert(id: 'concert-3');
      final created = await LocalTicketStore.instance.createTicket(concert: concert);
      final now = DateTime.parse('2026-08-10T12:00:00.000Z');
      await LocalTicketStore.instance.updateTicket(created.id, tornAt: now);

      final untouched = await LocalTicketStore.instance.updateTicket(
        created.id,
        review: '좋았어요',
      );
      expect(untouched.tornAt, now);
    });
  });
}
