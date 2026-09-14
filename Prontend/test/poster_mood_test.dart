import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/concert_after_palette.dart';

void main() {
  test('극단적인 포스터도 종이 밝기와 질감 범위를 유지한다', () {
    for (final value in [0.0, .5, 1.0]) {
      final mood = PosterMood(Colors.red, value, value, value, value);
      expect(mood.paperSaturation, inInclusiveRange(.06, .40));
      expect(mood.paperValue, inInclusiveRange(.80, .96));
      expect(mood.textureOpacity, inInclusiveRange(.09, .22));
      expect(
        HSVColor.fromColor(mood.paperColor).value,
        inInclusiveRange(.85, .985),
      );
      expect(mood.imageFilter, isA<ColorFilter>());
    }
  });
  test('포스터의 채도 밝기와 세부 변화가 종이에 반영된다', () {
    const low = PosterMood(Colors.blue, .1, .1, .1, .01);
    const high = PosterMood(Colors.blue, .9, .9, .4, .3);
    expect(high.paperSaturation, greaterThan(low.paperSaturation));
    expect(high.paperValue, greaterThan(low.paperValue));
    expect(high.textureOpacity, greaterThan(low.textureOpacity));
    expect(high.hue, low.hue);
  });
}
