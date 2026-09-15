import 'package:flutter/material.dart';

/// 포스터가 없을 때 공연마다 서로 다른 무드의 배경을 주기 위한 그라데이션
/// 팔레트. 제목 문자열에서 결정적으로(앱을 껐다 켜도 동일하게) 골라, 같은
/// 공연은 항상 같은 색을 갖습니다.
///
/// [diary_screen.dart]의 티켓 카드(`_PosterTicketFace`)와
/// `LandscapeUpcomingTicketPanel`(가로모드 동반 패널)이 같은 공연에 항상
/// 같은 색이 나오도록 이 하나만 공유해서 씁니다.
const List<List<Color>> posterFallbackPalettes = [
  [Color(0xFF241734), Color(0xFF7B4B94)], // 자주빛 밤
  [Color(0xFF0F2A43), Color(0xFF3E7CB1)], // 네이비
  [Color(0xFF3B2416), Color(0xFFB07D3D)], // 앰버 브라운
  [Color(0xFF12403C), Color(0xFF4C9A82)], // 딥 그린
  [Color(0xFF461426), Color(0xFFA34672)], // 버건디
];

List<Color> posterFallbackGradient(String seedText) {
  var h = 0;
  for (final c in seedText.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return posterFallbackPalettes[h % posterFallbackPalettes.length];
}
