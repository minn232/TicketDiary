import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'responsive_text.dart';

enum MapProvider { kakao, naver }

/// "카카오맵/네이버지도 중 선택" 바텀시트를 띄우고, 고른 지도 앱에서
/// [venue] 검색 링크를 엽니다. 소식 상세의 "공연장" 버튼과 가로모드
/// 다가오는 공연 패널이 함께 쓰는 공용 함수.
Future<void> showVenueMapPicker(BuildContext context, String venue) async {
  final choice = await showModalBottomSheet<MapProvider>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '지도 앱 선택',
                style: TextStyle(
                  fontSize: context.sp(15),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('카카오맵으로 보기'),
            onTap: () => Navigator.of(context).pop(MapProvider.kakao),
          ),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('네이버지도로 보기'),
            onTap: () => Navigator.of(context).pop(MapProvider.naver),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (choice == null) return;

  final query = Uri.encodeComponent(venue);
  final uri = switch (choice) {
    MapProvider.kakao => Uri.parse('https://map.kakao.com/link/search/$query'),
    MapProvider.naver => Uri.parse('https://map.naver.com/v5/search/$query'),
  };
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
