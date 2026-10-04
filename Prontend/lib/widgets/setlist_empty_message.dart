import '../models/setlist.dart';

// [백엔드 수정] 실제 셋리 빈 화면 문구 신규.

/// 빈 화면 문구 - 본문 한 줄 + (있으면) "♪ 곡 · 이름 기준" 보조 줄.
class SetlistEmptyText {
  final String main;
  final String? song;
  final String? name;

  /// 곡/이름 대신 쓰는 보조 문구.
  final String? note;

  const SetlistEmptyText(this.main, {this.song, this.name, this.note});
}

SetlistEmptyText setlistEmptyText(
  ArtistSetlistStatus? status, {
  bool refilling = false,
}) {
  if (refilling) return const SetlistEmptyText('셋리를 찾는 중이에요');
  switch (status?.state) {
    case 'searching':
    case 'searched':
      final song = status!.topSong;
      return SetlistEmptyText(
        status.state == 'searching' ? '셋리를 찾는 중이에요' : '아직 셋리가 없어요',
        song: song == null || song.isEmpty ? null : song,
        name: status.name ?? status.artist,
      );
    case 'unresolved':
      return const SetlistEmptyText('셋리를 찾지 못했어요', note: '누구인지 확정하지 못했어요');
    case 'not_artist':
      return const SetlistEmptyText('셋리를 찾지 않아요', note: '아티스트가 아닌 것으로 설정됨');
    default:
      return const SetlistEmptyText('아직 셋리가 없어요');
  }
}
