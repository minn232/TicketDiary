import 'package:flutter/material.dart';

const Color kDiaryPageBaseColor = Color(0xFFF4F1E1);
const double kConcertAfterDiaryPageHue = 50.52631578947363;
const double kConcertAfterPaperSaturation = .07786885245901637;
const double kConcertAfterPaperValue = .9568627450980393;
const double kConcertAfterDecorationAlpha = .3;

// 노트 줄: 간격, 두께, 불투명도 (논리 픽셀 기준).
const double kConcertAfterRuleSpacing = 28;
const double kConcertAfterRuleWidth = .65;
const double kConcertAfterRuleAlpha = .25;

Color concertAfterTone({
  required double hue,
  double alpha = 1,
  double saturation = kConcertAfterPaperSaturation,
  double value = kConcertAfterPaperValue,
}) {
  return HSVColor.fromAHSV(alpha, hue % 360, saturation, value).toColor();
}

// false로 변경하면 포스터 분석 전 디자인으로 돌아간다.
const bool kConcertAfterPosterMoodEnabled = true;
const double kPosterMoodSaturationInfluence = .38;
const double kPosterMoodBrightnessInfluence = .18;
const double kPosterMoodTextureInfluence = .65;

class PosterMood {
  final Color accent;
  final double saturation, brightness, contrast, detail;
  const PosterMood(
    this.accent,
    this.saturation,
    this.brightness,
    this.contrast,
    this.detail,
  );
  double get hue => HSVColor.fromColor(accent).hue;
  double get paperSaturation =>
      (.06 + saturation * kPosterMoodSaturationInfluence).clamp(.06, .40);
  double get paperValue =>
      (.80 + brightness * kPosterMoodBrightnessInfluence).clamp(.80, .96);
  double get textureOpacity =>
      (.09 + detail * kPosterMoodTextureInfluence).clamp(.09, .22);
  Color get paperColor => concertAfterTone(
    hue: kConcertAfterDiaryPageHue,
    saturation: paperSaturation * .32,
    value: (paperValue + .04).clamp(.86, .98),
  );
  Color get materialColor => concertAfterTone(
    hue: hue,
    saturation: paperSaturation,
    value: paperValue,
  );
}

class PosterMoodScope extends InheritedWidget {
  final PosterMood? mood;
  const PosterMoodScope({super.key, required this.mood, required super.child});
  static PosterMood? of(BuildContext context) => kConcertAfterPosterMoodEnabled
      ? context.dependOnInheritedWidgetOfExactType<PosterMoodScope>()?.mood
      : null;
  @override
  bool updateShouldNotify(PosterMoodScope oldWidget) => mood != oldWidget.mood;
}
