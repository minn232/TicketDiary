import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/setlist.dart';
import 'package:ticketdiary/widgets/setlist_empty_message.dart';

const _searched = ArtistSetlistStatus(
  artist: 'Lany',
  state: 'searched',
  name: 'LANY',
  topSong: 'Malibu Nights',
);

List<String> _texts(ArtistSetlistStatus? status, {bool refilling = false}) => [
  for (final w in setlistEmptyMessageWords(status, refilling: refilling))
    w.text,
];

Future<void> _pump(WidgetTester tester, Widget child, double width) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

void main() {
  test('곡의 첫 단어에 ♪, 마지막 단어에 "의"를 붙여 따로 줄바꿈되지 않게 한다', () {
    expect(_texts(_searched), [
      '♪ Malibu',
      'Nights의',
      'LANY',
      '셋리를',
      '찾아봤지만',
      '아직',
      '없어요',
    ]);
  });

  test('한 단어짜리 곡은 ♪와 "의"를 모두 붙인다', () {
    const status = ArtistSetlistStatus(
      artist: 'YOASOBI',
      state: 'searching',
      name: 'YOASOBI',
      topSong: 'Idol',
    );
    expect(_texts(status).take(3), ['♪ Idol의', 'YOASOBI', '셋리를']);
    expect(_texts(status).last, '중이에요');
  });

  test('대표곡이 없으면 이름부터, 이름이 없으면 공연 표기를 쓴다', () {
    const status = ArtistSetlistStatus(artist: '자이로', state: 'searched');
    expect(_texts(status).first, '자이로');
  });

  test('상태별 문구', () {
    expect(
      _texts(
        const ArtistSetlistStatus(artist: 'a', state: 'unresolved'),
      ).join(' '),
      '누구인지 확정하지 못해 셋리를 찾지 못했어요',
    );
    expect(
      _texts(
        const ArtistSetlistStatus(artist: 'a', state: 'not_artist'),
      ).join(' '),
      '아티스트가 아닌 것으로 설정돼 있어요',
    );
    expect(_texts(null).join(' '), '아직 등록되지 않았어요');
    expect(_texts(_searched, refilling: true).join(' '), '셋리를 다시 찾는 중이에요');
  });

  testWidgets('좁은 칸에서도 단어가 중간에서 끊기지 않는다', (tester) async {
    await _pump(
      tester,
      const SetlistEmptyMessage(status: _searched, ink: Colors.brown),
      110,
    );

    final texts = tester.widgetList<Text>(find.byType(Text)).toList();
    expect(texts.map((t) => t.data), _texts(_searched));
    expect(texts.every((t) => t.maxLines == 1), isTrue);
    for (final word in _texts(_searched)) {
      final size = tester.getSize(find.text(word));
      expect(size.width, lessThanOrEqualTo(110));
    }
    final rows = {
      for (final word in _texts(_searched))
        tester.getTopLeft(find.text(word)).dy,
    };
    expect(rows.length, greaterThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('칸보다 긴 단어는 넘치지 않고 말줄임된다', (tester) async {
    const status = ArtistSetlistStatus(
      artist: 'x',
      state: 'searched',
      name: 'X',
      topSong: 'Supercalifragilisticexpialidocious',
    );
    await _pump(
      tester,
      const SetlistEmptyMessage(status: status, ink: Colors.brown),
      110,
    );

    final longWord = find.text('♪ Supercalifragilisticexpialidocious의');
    expect(tester.getSize(longWord).width, lessThanOrEqualTo(110));
    expect(tester.takeException(), isNull);
  });

  test('균형 줄바꿈 - 줄 수는 그대로, 마지막 줄 외톨이 단어 없이 고르게', () {
    // 그냥 채우면 "40 40 40 / 10", 균형 폭이면 "40 40 / 40 10"
    const widths = [40.0, 40.0, 40.0, 10.0];
    final width = balancedWrapWidth(widths, spacing: 4, maxWidth: 130);
    expect(width, lessThan(130));
    expect(width, greaterThanOrEqualTo(84));
  });

  test('한 줄에 다 들어가면 폭을 줄이지 않는다', () {
    expect(balancedWrapWidth([10, 10], spacing: 2, maxWidth: 100), 100);
  });
}
