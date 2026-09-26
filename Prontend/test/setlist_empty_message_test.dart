import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/setlist.dart';
import 'package:ticketdiary/widgets/setlist_empty_message.dart';

void main() {
  test('찾아봤지만 없으면 본문 + 곡·이름 보조 줄', () {
    final text = setlistEmptyText(
      const ArtistSetlistStatus(
        artist: '자이로',
        state: 'searched',
        name: '자이로',
        topSong: 'Smooth',
      ),
    );
    expect(text.main, '아직 셋리가 없어요');
    expect(text.song, 'Smooth');
    expect(text.name, '자이로');
  });

  test('찾는 중이면 본문만 바뀌고, 대표곡이 없으면 이름만, 이름이 없으면 공연 표기', () {
    final text = setlistEmptyText(
      const ArtistSetlistStatus(artist: 'Lany', state: 'searching'),
    );
    expect(text.main, '셋리를 찾는 중이에요');
    expect(text.song, isNull);
    expect(text.name, 'Lany');
  });

  test('확정 못함/아티스트 아님은 곡 대신 안내 문구', () {
    final unresolved = setlistEmptyText(
      const ArtistSetlistStatus(artist: 'a', state: 'unresolved'),
    );
    expect(unresolved.main, '셋리를 찾지 못했어요');
    expect(unresolved.note, '누구인지 확정하지 못했어요');
    expect(unresolved.name, isNull);

    final notArtist = setlistEmptyText(
      const ArtistSetlistStatus(artist: 'a', state: 'not_artist'),
    );
    expect(notArtist.note, '아티스트가 아닌 것으로 설정됨');
  });

  test('상태가 없거나 다시 찾는 중', () {
    expect(setlistEmptyText(null).main, '아직 셋리가 없어요');
    expect(
      setlistEmptyText(
        const ArtistSetlistStatus(artist: 'a', state: 'searched'),
        refilling: true,
      ).main,
      '셋리를 찾는 중이에요',
    );
  });
}
