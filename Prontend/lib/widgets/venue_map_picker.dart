import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'paper_style.dart';

enum MapProvider { kakao, naver }

/// "카카오맵/네이버지도 중 선택" 바텀시트를 띄우고, 고른 지도 앱에서
/// [venue] 검색 링크를 엽니다. 소식 상세의 "공연장" 버튼과 가로모드
/// 다가오는 공연 패널이 함께 쓰는 공용 함수.
Future<void> showVenueMapPicker(BuildContext context, String venue) async {
  final choice = await showPaperSheet<MapProvider>(
    context,
    title: '어떤 지도로 볼까요?',
    rows: (context) => [
      PaperSheetRow(
        leading: const Icon(Icons.map_outlined, color: PaperColors.muted),
        title: '카카오맵',
        onTap: () => Navigator.of(context).pop(MapProvider.kakao),
      ),
      PaperSheetRow(
        leading: const Icon(Icons.map_outlined, color: PaperColors.muted),
        title: '네이버지도',
        onTap: () => Navigator.of(context).pop(MapProvider.naver),
      ),
    ],
  );

  if (choice == null) return;

  final query = Uri.encodeComponent(venue);
  final uri = switch (choice) {
    MapProvider.kakao => Uri.parse('https://map.kakao.com/link/search/$query'),
    MapProvider.naver => Uri.parse('https://map.naver.com/v5/search/$query'),
  };
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
