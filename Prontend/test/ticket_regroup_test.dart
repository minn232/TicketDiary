import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/screen/diary_screen.dart';

TicketData _day(
  String id,
  String concertId,
  DateTime date, {
  TicketStatus status = TicketStatus.afterConcert,
  String? passGroupId,
  String price = '',
}) => TicketData(
  id: id,
  title: '공연 $concertId',
  status: status,
  passGroupId: passGroupId,
  info: TicketInfo(concertId: concertId, date: date, price: price),
);

void main() {
  final d1 = DateTime.utc(2030, 2, 15);
  final d2 = DateTime.utc(2030, 2, 16);
  final d3 = DateTime.utc(2030, 2, 17);

  test('같은 공연을 날마다 따로 산 티켓은 카드 한 장으로 묶이고 가격은 각자 그대로', () {
    final cards = regroupTickets([
      _day('a', 'c1', d2, price: '110000'),
      _day('x', 'c2', d1),
      _day('b', 'c1', d1, price: '99000'),
    ]);

    expect(cards, hasLength(2));
    final group = cards.first.passGroup!;
    expect(group.days.map((d) => d.id), ['b', 'a']);
    expect(group.isSinglePass, isFalse);
    expect(group.label, '2회 관람 · 02.15~02.16');
    expect(group.days.map((d) => d.info!.price), ['99000', '110000']);
    expect(cards.last.passGroup, isNull);
  });

  test('배송 전 티켓은 받기 전까진 따로, 받으면 합쳐짐', () {
    final waiting = _day('b', 'c1', d2, status: TicketStatus.beforeDelivery);
    final cards = regroupTickets([_day('a', 'c1', d1), waiting]);
    expect(cards, hasLength(2));
    expect(cards.every((c) => c.passGroup == null), isTrue);

    final received = _day('b', 'c1', d2, status: TicketStatus.beforeConcert);
    final merged = regroupTickets([cards.first, received], focusId: 'b');
    expect(merged, hasLength(1));
    expect(merged.single.id, 'b');
    expect(merged.single.passGroup!.days, hasLength(2));
  });

  test('2일권에 따로 산 날이 더해지면 "회 관람"이고 2일권 가격은 같이 산 날에만', () {
    final cards = regroupTickets([
      _day('p1', 'c1', d1, passGroupId: 'p1', price: '180000'),
      _day('p2', 'c1', d2, passGroupId: 'p1'),
      _day('s', 'c1', d3),
    ]);

    final group = cards.single.passGroup!;
    expect(group.label, '3회 관람 · 02.15~02.17');
    expect(group.days.map((d) => d.info!.price), ['180000', '180000', '']);
    expect(group.boughtWith(group.days[1]).map((d) => d.id), ['p1', 'p2']);
    expect(group.boughtWith(group.days[2]).map((d) => d.id), ['s']);
  });

  test('2일권만 묶이면 "일권" 표기', () {
    final cards = regroupTickets([
      _day('p1', 'c1', d1, passGroupId: 'p1'),
      _day('p2', 'c1', d3, passGroupId: 'p1'),
    ]);
    expect(cards.single.passGroup!.label, '2일권 · 02.15, 02.17');
  });
}
