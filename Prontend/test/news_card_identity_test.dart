import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/services/news_card_identity.dart';

NewsModel card(String id, String concertId) => NewsModel(
  id: id,
  concertId: concertId,
  artist: 'artist',
  concert: 'same name',
  imageUrl: '',
  description: '',
);

void main() {
  test('individual feed survives reorder among same-concert cards', () {
    final a = card('a', 'concert');
    final b = card('b', 'concert');
    expect(findNewsCard([b, a], key: newsCardKey(a), concertId: 'concert'), 1);
  });
  test('removed target does not select another concert by shared title', () {
    expect(
      findNewsCard(
        [card('b', 'other')],
        key: 'feed:a',
        concertId: 'gone',
        name: 'same name',
      ),
      -1,
    );
  });
  test('concert fallback only resolves an unambiguous card', () {
    expect(findNewsCard([card('a', 'c'), card('b', 'c')], concertId: 'c'), -1);
    expect(findNewsCard([card('b', 'c')], concertId: 'c'), 0);
    expect(findNewsCard([], concertId: 'c'), -1);
  });
}
