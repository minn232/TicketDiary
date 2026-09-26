import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/setlist.dart';
import 'responsive_text.dart';

// [백엔드 수정] 실제 셋리 빈 화면 문구 신규.

/// 문구 한 조각의 역할(스타일 구분용).
enum SetlistMessageRole { plain, song, name }

/// 줄바꿈 단위(단어) 하나.
class SetlistMessageWord {
  final String text;
  final SetlistMessageRole role;

  const SetlistMessageWord(this.text, [this.role = SetlistMessageRole.plain]);
}

List<SetlistMessageWord> _words(
  String text, [
  SetlistMessageRole role = SetlistMessageRole.plain,
]) => [
  for (final word in text.split(' '))
    if (word.isNotEmpty) SetlistMessageWord(word, role),
];

/// 상태별 문구를 단어 단위로 나눔("♪"와 "의"는 곡 단어에 붙임).
List<SetlistMessageWord> setlistEmptyMessageWords(
  ArtistSetlistStatus? status, {
  bool refilling = false,
}) {
  if (refilling) return _words('셋리를 다시 찾는 중이에요');
  switch (status?.state) {
    case 'searching':
    case 'searched':
      final name = status!.name ?? status.artist;
      final song = status.topSong;
      final words = <SetlistMessageWord>[];
      if (song != null && song.isNotEmpty) {
        final songWords = _words(song, SetlistMessageRole.song);
        for (var i = 0; i < songWords.length; i++) {
          final prefix = i == 0 ? '♪ ' : '';
          final suffix = i == songWords.length - 1 ? '의' : '';
          words.add(
            SetlistMessageWord(
              '$prefix${songWords[i].text}$suffix',
              SetlistMessageRole.song,
            ),
          );
        }
      }
      words.addAll(_words(name, SetlistMessageRole.name));
      words.addAll(
        _words(
          status.state == 'searching' ? '셋리를 찾는 중이에요' : '셋리를 찾아봤지만 아직 없어요',
        ),
      );
      return words;
    case 'unresolved':
      return _words('누구인지 확정하지 못해 셋리를 찾지 못했어요');
    case 'not_artist':
      return _words('아티스트가 아닌 것으로 설정돼 있어요');
    default:
      return _words('아직 등록되지 않았어요');
  }
}

/// 실제 셋리 빈 화면 문구(단어 단위 줄바꿈, 칸보다 긴 단어는 말줄임).
class SetlistEmptyMessage extends StatelessWidget {
  final ArtistSetlistStatus? status;
  final bool refilling;
  final Color ink;
  final double fontSize;
  final WrapAlignment alignment;

  const SetlistEmptyMessage({
    super.key,
    this.status,
    this.refilling = false,
    required this.ink,
    this.fontSize = 12,
    this.alignment = WrapAlignment.center,
  });

  TextStyle _style(BuildContext context, SetlistMessageRole role) {
    final base = TextStyle(
      fontSize: context.sp(fontSize),
      fontWeight: FontWeight.w700,
      color: ink.withValues(alpha: 0.5),
      height: 1.4,
    );
    switch (role) {
      case SetlistMessageRole.plain:
        return base;
      case SetlistMessageRole.song:
        return base.copyWith(
          fontWeight: FontWeight.w600,
          fontStyle: FontStyle.italic,
          color: ink.withValues(alpha: 0.65),
        );
      case SetlistMessageRole.name:
        return base.copyWith(
          fontWeight: FontWeight.w900,
          color: ink.withValues(alpha: 0.8),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final words = setlistEmptyMessageWords(status, refilling: refilling);
    final spacing = context.sp(fontSize) * 0.28;
    final textScaler = MediaQuery.textScalerOf(context);
    final wordWidths = [
      for (final word in words)
        (TextPainter(
          text: TextSpan(text: word.text, style: _style(context, word.role)),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
          maxLines: 1,
        )..layout()).width,
    ];

    final wrap = Wrap(
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: spacing,
      children: [
        for (final word in words)
          Text(
            word.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _style(context, word.role),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth) return wrap;
        final width = balancedWrapWidth(
          wordWidths,
          spacing: spacing,
          maxWidth: constraints.maxWidth,
        );
        return SizedBox(width: width, child: wrap);
      },
    );
  }
}

/// 균형 줄바꿈 폭 - 줄 수는 유지하고 줄 길이를 고르게 맞춤.
double balancedWrapWidth(
  List<double> wordWidths, {
  required double spacing,
  required double maxWidth,
}) {
  if (wordWidths.isEmpty) return 0;
  int lineCount(double width) {
    var lines = 1;
    var used = 0.0;
    for (final w in wordWidths) {
      final needed = used == 0 ? w : used + spacing + w;
      if (used > 0 && needed > width) {
        lines++;
        used = w;
      } else {
        used = needed;
      }
    }
    return lines;
  }

  final target = lineCount(maxWidth);
  if (target == 1) return maxWidth;
  var lo = math.min(wordWidths.reduce(math.max), maxWidth);
  var hi = maxWidth;
  for (var i = 0; i < 20 && hi - lo > 0.5; i++) {
    final mid = (lo + hi) / 2;
    if (lineCount(mid) <= target) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  // 측정 오차 여유.
  return math.min(maxWidth, hi + 1);
}
