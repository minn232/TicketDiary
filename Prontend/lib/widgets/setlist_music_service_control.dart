import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_settings_store.dart';
import '../services/music_link_resolve_service.dart';
import '../services/music_service_links.dart';

/// 셋리스트 화면(포스트잇/기사) 하나를 보는 동안만 유지되는 "지금 어느
/// 서비스로 연결할지" 선택값. 초기값은 설정탭 기본값을 그대로 물려받지만,
/// 꾹 눌러서 바꾼 값은 이 화면 인스턴스에만 적용되고 설정탭 기본값 자체는
/// 건드리지 않습니다(화면을 나갔다 들어오면 다시 설정탭 기본값으로 리셋) -
/// 그래야 곡 하나 때문에 우연히 바꾼 값이 이후 전체 기본값으로 굳어버리는
/// 걸 막을 수 있음.
class SetlistServiceSelection extends ValueNotifier<MusicService> {
  SetlistServiceSelection()
      : super(AppSettingsStore.instance.preferredMusicService);
}

/// 포스트잇/기사 헤더 한 켠에 놓는 작은 서비스 아이콘. 꾹 누르면 다른
/// 서비스로 바꿀 수 있는 팝업 메뉴가 뜸(탭만으로는 안 바뀜 - 실수로 스크롤
/// 하다 바뀌는 걸 방지).
class SetlistServiceIcon extends StatelessWidget {
  final SetlistServiceSelection selection;
  final double size;

  const SetlistServiceIcon({
    super.key,
    required this.selection,
    this.size = 16,
  });

  Future<void> _openPicker(BuildContext context, Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final picked = await showMenu<MusicService>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final service in MusicService.values)
          PopupMenuItem(
            value: service,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.asset(service.iconAsset, width: 18, height: 18),
                ),
                const SizedBox(width: 8),
                Text(service.label),
              ],
            ),
          ),
      ],
    );
    if (picked != null) selection.value = picked;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MusicService>(
      valueListenable: selection,
      builder: (context, current, _) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (details) =>
              _openPicker(context, details.globalPosition),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.asset(current.iconAsset, width: size, height: size),
            ),
          ),
        );
      },
    );
  }
}

final MusicLinkResolveService _resolveService = MusicLinkResolveService();

/// 곡 한 줄을 눌렀을 때 [selection]에 담긴 현재 서비스로 연결합니다.
/// [artist]가 없으면(단독 공연에서 아티스트 태그가 비었을 때) [fallbackArtist]를
/// 대신 씀(예: 실제 셋리스트의 콘서트 등록 아티스트 전원 목록이 1명뿐일 때).
///
/// 먼저 백엔드에 정확한 트랙/영상을 물어봐서(`MusicLinkResolveService`) 찾으면
/// 그 링크로 원탭 직결하고, 못 찾으면(비공식 발매곡 등) 기존처럼 검색화면을
/// 엽니다 - 실패가 항상 "검색화면"으로 안전하게 떨어지도록.
Future<void> openSetlistSongSearch(
  ValueListenable<MusicService> selection, {
  String? artist,
  String? fallbackArtist,
  required String songName,
}) async {
  final service = selection.value;
  final effectiveArtist =
      (artist != null && artist.trim().isNotEmpty) ? artist : fallbackArtist;

  final resolved = await _resolveService.resolve(
    service,
    artist: effectiveArtist,
    song: songName,
  );
  if (resolved != null) {
    try {
      await launchUrl(resolved, mode: LaunchMode.externalApplication);
      return;
    } catch (_) {
      // 링크는 받았는데 실행에 실패하면(설치 안 된 앱 등) 검색화면으로 폴백.
    }
  }
  await openMusicSearch(service, artist: effectiveArtist, song: songName);
}
