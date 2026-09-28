import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/services/photo_quality.dart';

/// 64×64 회색조 RGBA. [pixel]이 (x, y)의 밝기(0~255)를 정함.
PhotoStats _stats(int Function(int x, int y) pixel) {
  const size = 64;
  final rgba = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final v = pixel(x, y).clamp(0, 255);
      final i = (y * size + x) * 4;
      rgba[i] = rgba[i + 1] = rgba[i + 2] = v;
      rgba[i + 3] = 255;
    }
  }
  return PhotoStats.fromRgba(rgba, size, size);
}

void main() {
  test('경계가 또렷한 사진이 흐린 사진보다 선명도 높음', () {
    final sharp = _stats((x, y) => ((x ~/ 4) + (y ~/ 4)).isEven ? 40 : 200);
    final blurry = _stats((x, y) => 40 + (x * 160 ~/ 63));
    expect(sharp.sharpness, greaterThan(blurry.sharpness * 10));
  });

  test('밝기 / 날아간 픽셀 비율', () {
    final white = _stats((x, y) => 255);
    expect(white.brightness, closeTo(1, 1e-9));
    expect(white.highlightClip, 1);
    final dark = _stats((x, y) => 0);
    expect(dark.shadowClip, 1);
    expect(white.exposure, lessThan(_stats((x, y) => 100).exposure));
  });

  test('세트 내 상대 순위: 선명하고 노출 좋은 사진이 1등, 한 장이면 0.5', () {
    final good = _stats((x, y) => ((x ~/ 4) + (y ~/ 4)).isEven ? 60 : 160);
    final blurryDark = _stats((x, y) => 20 + x ~/ 8);
    final blown = _stats((x, y) => 250);
    final scores = scorePhotoSet([blurryDark, good, blown]);
    expect(scores[1], 1.0);
    expect(scores[1], greaterThan(scores[0]));
    expect(scores[1], greaterThan(scores[2]));
    expect(scorePhotoSet([good]), [0.5]);
    expect(scorePhotoSet(const []), isEmpty);
  });

  test('유사샷 묶기: 시각이 가깝고 색 배치가 비슷해야 같은 그룹', () {
    final a = _stats((x, y) => x < 32 ? 40 : 180);
    final aLike = _stats((x, y) => x < 32 ? 44 : 176);
    final other = _stats((x, y) => y < 32 ? 200 : 30);
    final t = DateTime(2026, 9, 5, 12, 49, 19);
    final groups = groupSimilarShots([
      ShotInfo(takenAt: t, stats: a),
      ShotInfo(takenAt: t.add(const Duration(seconds: 2)), stats: aLike),
      // 시각은 가깝지만 다른 장면.
      ShotInfo(takenAt: t.add(const Duration(seconds: 4)), stats: other),
      // 장면은 같지만 한참 뒤.
      ShotInfo(takenAt: t.add(const Duration(minutes: 5)), stats: aLike),
      // 촬영 시각 없음 → 묶지 않음.
      ShotInfo(takenAt: null, stats: a),
    ]);
    expect(groups[0], isNotNull);
    expect(groups[1], groups[0]);
    expect(groups[2], isNull);
    expect(groups[3], isNull);
    expect(groups[4], isNull);
  });
}
