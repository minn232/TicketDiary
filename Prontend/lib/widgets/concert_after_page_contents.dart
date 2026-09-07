import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../models/setlist.dart';
import '../models/ticket_info.dart';
import '../services/api_client.dart';
import '../services/concert_detail_service.dart';
import '../services/ticket_service.dart';
import '../services/upload_service.dart';
import 'responsive_text.dart';
import 'scrapbook_page_background.dart';
import 'app_network_image.dart';

/// 게스트 로그인 상태에서 로컬에 저장된 사진은 절대 파일 경로 문자열이라
/// `http(s)`로 시작하지 않습니다 — 이 차이로 [Image.network]/[Image.file] 중
/// 무엇을 쓸지 결정합니다.
bool _isNetworkUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

/// "공연 후" 페이지 콘텐츠.
///
/// - 상단에 일기장 표제처럼 공연 제목/날짜/공연장 + 빨간 "관람 완료" 도장
/// - 사진/공연 소감/업적 도장/실제 셋리스트 4개 기능을 스크롤·스와이프 없이
///   한 화면에 2x2 포스트잇 색 카드로 모두 보여줌
///
/// NOTE ([ConcertBeforePageContents]와 동일한 규칙)
/// - 오버레이에서는 [postItOpacity]에 애니메이션을 넘기면 2x2 카드 영역이
///   Fade-in 됩니다(헤더는 즉시 보임). 일반 스크린에서는 null로 두면
///   즉시 표시됩니다.
/// - [ticketInfo]가 있어야 사진/소감/실제 셋리스트를 서버에 반영할 수
///   있습니다(없으면 로컬 예시 티켓이라 조회/편집 없이 안내 문구만 표시).
class ConcertAfterPageContents extends StatefulWidget {
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final Animation<double>? postItOpacity;
  final bool showCloseHint;

  /// 사진 추가/소감 저장이 성공해 [ticketInfo]가 최신화될 때마다 호출됩니다.
  /// 호출자(다이어리 화면)가 원본 티켓 데이터를 같이 갱신해야, 이 오버레이를
  /// 닫은 뒤에도 앱 재시작 없이 바로 최신 내용이 보입니다.
  final ValueChanged<TicketInfo>? onTicketInfoChanged;

  const ConcertAfterPageContents({
    super.key,
    required this.concertTitle,
    this.ticketInfo,
    this.postItOpacity,
    this.showCloseHint = true,
    this.onTicketInfoChanged,
  });

  @override
  State<ConcertAfterPageContents> createState() =>
      _ConcertAfterPageContentsState();
}

class _ConcertAfterPageContentsState extends State<ConcertAfterPageContents> {
  final TicketService _ticketService = TicketService();
  final UploadService _uploadService = BackendUploadService();
  final ImagePicker _imagePicker = ImagePicker();

  late TicketInfo? _ticketInfo = widget.ticketInfo;
  bool _uploadingPhoto = false;

  String? get _ticketId => _ticketInfo?.ticketId;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 로컬 예시 티켓 등 서버에 등록되지 않은 티켓은 편집할 수 없음을 안내합니다.
  bool _ensureEditable() {
    if (_ticketId != null) return true;
    _showSnack('실제 등록된 티켓만 편집할 수 있어요.');
    return false;
  }

  /// 인라인 텍스트 상자에서 편집이 끝나면(포커스 해제/닫힘) 호출됩니다.
  /// 별도 다이얼로그 없이 바로 저장합니다(변경이 없으면 아무 것도 안 함).
  Future<void> _saveReviewInline(String text) async {
    final trimmed = text.trim();
    if (trimmed == (_ticketInfo?.review ?? '')) return; // 변경 없음
    if (_ticketId == null) {
      // 서버 미등록(로컬 예시) 티켓 — 저장은 못 하지만 화면 상태는 유지.
      return;
    }
    try {
      final updated =
          await _ticketService.updateTicket(_ticketId!, review: trimmed);
      if (!mounted) return;
      setState(() {
        _ticketInfo = _ticketInfo?.copyWith(review: updated.review ?? trimmed);
      });
      if (_ticketInfo != null) widget.onTicketInfoChanged?.call(_ticketInfo!);
    } catch (_) {
      // 인라인 저장 실패는 조용히 무시(다음 편집/재시도 때 다시 저장 시도).
    }
  }

  /// [slotAspectRatio]는 폴라로이드 사진 자리의 가로/세로 비율([_PhotoBoard]가
  /// 실제 카드 크기에서 계산해 넘겨줌). 사용자가 갤러리에서 고른 사진을 이
  /// 비율에 맞춰 직접 확대/이동하며 자르게 한 뒤 업로드합니다.
  Future<void> _addPhoto(double slotAspectRatio) async {
    if (!_ensureEditable() || _uploadingPhoto) return;
    if ((_ticketInfo?.concertPhotoUrls ?? const <String>[]).isNotEmpty) {
      _showSnack('사진은 한 장만 첨부할 수 있어요.');
      return;
    }

    final XFile? picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (picked == null) return; // 취소

    final CroppedFile? cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: CropAspectRatio(ratioX: slotAspectRatio, ratioY: 1),
      compressQuality: 90,
      uiSettings: [
        IOSUiSettings(
          title: '사진 편집',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
        AndroidUiSettings(
          toolbarTitle: '사진 편집',
          lockAspectRatio: true,
        ),
      ],
    );
    if (cropped == null || !mounted) return; // 편집 취소

    setState(() => _uploadingPhoto = true);
    try {
      final url = await _uploadService.uploadConcertPhoto(XFile(cropped.path));
      final List<String> nextUrls = [
        ...(_ticketInfo?.concertPhotoUrls ?? const <String>[]),
        url,
      ];
      final updated = await _ticketService.updateTicket(
        _ticketId!,
        concertPhotoUrls: nextUrls,
      );
      if (!mounted) return;
      setState(() {
        _ticketInfo = _ticketInfo?.copyWith(
          concertPhotoUrls: updated.concertPhotoUrls ?? nextUrls,
        );
      });
      if (_ticketInfo != null) widget.onTicketInfoChanged?.call(_ticketInfo!);
    } on TicketNotFoundException {
      _showSnack('티켓을 찾을 수 없어요.');
    } on ApiException catch (e) {
      _showSnack('사진 추가에 실패했어요: ${e.message}');
    } catch (_) {
      _showSnack('사진 추가 중 오류가 발생했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  // [백엔드 수정]
  // 사진을 꾹 눌러서 삭제할 수 있는 기능.
  // 확인 팝업 후 서버에서 삭제.
  Future<void> _confirmDeletePhoto(String url) async {
    if (!_ensureEditable() || _uploadingPhoto) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('사진 삭제'),
        content: const Text('이 사진을 삭제할까요? 되돌릴 수 없어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final List<String> nextUrls = [
      ...(_ticketInfo?.concertPhotoUrls ?? const <String>[]),
    ]..remove(url);

    try {
      final updated = await _ticketService.updateTicket(
        _ticketId!,
        concertPhotoUrls: nextUrls,
      );
      if (!mounted) return;
      setState(() {
        _ticketInfo = _ticketInfo?.copyWith(
          concertPhotoUrls: updated.concertPhotoUrls ?? nextUrls,
        );
      });
      if (_ticketInfo != null) widget.onTicketInfoChanged?.call(_ticketInfo!);
      _showSnack('사진을 삭제했어요.');
    } on TicketNotFoundException {
      _showSnack('티켓을 찾을 수 없어요.');
    } on ApiException catch (e) {
      _showSnack('사진 삭제에 실패했어요: ${e.message}');
    } catch (_) {
      _showSnack('사진 삭제 중 오류가 발생했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final photoUrls = _ticketInfo?.concertPhotoUrls ?? const <String>[];

    // 첨부한 스크랩북처럼, 크래프트 종이 위에 메모지(포스터/공연정보/폴라로이드
    // 사진/실제 셋리스트/공연 후기/타임테이블)를 겹쳐 붙이고, 편집모드에서
    // 드래그 이동·두 손가락 확대축소·회전·후기 타이핑을 할 수 있는 캔버스입니다.
    final canvas = _ScrapbookCanvas(
      layoutKey: _ticketId ?? 'local_after_${identityHashCode(this)}',
      concertTitle: widget.concertTitle,
      ticketInfo: _ticketInfo,
      reviewText: _ticketInfo?.review,
      onReviewChanged: _saveReviewInline,
      photoUrl: photoUrls.isNotEmpty ? photoUrls.first : null,
      uploadingPhoto: _uploadingPhoto,
      onAddPhoto: _uploadingPhoto ? null : _addPhoto,
      onDeletePhoto: _uploadingPhoto ? null : _confirmDeletePhoto,
      setlistTicketId: _ticketId,
      concertId: _ticketInfo?.concertId,
    );

    return widget.postItOpacity == null
        ? canvas
        : FadeTransition(opacity: widget.postItOpacity!, child: canvas);
  }
}


// [백엔드 수정]
// /concerts/{concertId}/setlist → /tickets/{ticketId}/setlist.
// 티켓 기준 라우트로 날짜를 자동으로 확인. 게스트도 이제 서버 ticketId를
// 가지므로, 예전에 있던 concertId 기준 게스트 전용 폴백은 제거.
/// "실제 셋리스트" 포스트잇 안에 들어가는 내용. ticketId가 있으면
/// `GET /tickets/{ticketId}/setlist`로 실제 데이터를 불러오고, 없거나
/// 아직 등록 전이면 안내 문구 표시.
class _RealSetlistContent extends StatefulWidget {
  final String? ticketId;
  final Color ink;

  const _RealSetlistContent({required this.ticketId, this.ink = _kraftInk});

  @override
  State<_RealSetlistContent> createState() => _RealSetlistContentState();
}

class _RealSetlistContentState extends State<_RealSetlistContent> {
  final ConcertDetailService _service = ConcertDetailService();
  List<SongEntry>? _songs;
  List<String> _artistNames = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ticketId = widget.ticketId;
    if (ticketId == null) return;
    try {
      final res = await _service.getRealSetlist(ticketId);
      if (!mounted) return;
      setState(() {
        // [백엔드 수정]
        // 앙코르가 시작되는 지점에 구분선(build에서 처리).
        _songs = res.songs;
        // [백엔드 수정] artistNames도 같이 저장(build()에서 아티스트별 그룹핑에 사용).
        _artistNames = res.artistNames;
      });
    } on ApiException catch (_) {
      // 조회 자체가 실패하면(네트워크 오류 등) 조용히 안내 문구를 유지합니다.
    } catch (_) {}
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.music_note_outlined,
            size: 22,
            color: widget.ink.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 6),
          Text(
            '아직 등록되지\n않았어요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(12),
              fontWeight: FontWeight.w700,
              color: widget.ink.withValues(alpha: 0.5),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final songs = _songs ?? const <SongEntry>[];
    if (songs.isEmpty && _artistNames.length <= 1) return _buildEmptyState();

    final songsByArtist = <String, List<SongEntry>>{};
    final untaggedSongs = <SongEntry>[];
    for (final song in songs) {
      final artist = song.artist;
      if (artist != null && artist.isNotEmpty) {
        songsByArtist.putIfAbsent(artist, () => []).add(song);
      } else {
        untaggedSongs.add(song);
      }
    }

    // [백엔드 수정] artistNames와 songs의 아티스트 태그를 합쳐서 그룹 뼈대를 만듦.
    final allArtists = [
      ..._artistNames,
      for (final name in songsByArtist.keys)
        if (!_artistNames.contains(name)) name,
    ];

    // 아티스트가 1명 이하(단독 공연, 또는 아티스트 태그 정보 자체가 없는 옛날
    // 데이터)면 기존처럼 번호 목록.
    if (allArtists.length <= 1 && untaggedSongs.isEmpty) {
      final only = allArtists.isEmpty ? songs : songsByArtist[allArtists.first]!;
      if (only.isEmpty) return _buildEmptyState();
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _buildRealSongRows(context, only, widget.ink),
        ),
      );
    }

    final groupList = [
      for (final name in allArtists)
        MapEntry<String?, List<SongEntry>>(name, songsByArtist[name] ?? const []),
      if (untaggedSongs.isNotEmpty)
        MapEntry<String?, List<SongEntry>>(null, untaggedSongs),
    ];

    return SingleChildScrollView(
      child: _RealSetlistGroupedByArtist(groups: groupList, ink: widget.ink),
    );
  }
}

// [백엔드 수정]
// 곡마다 번호 매긴 Row + 앙코르 시작 지점 구분선을 만드는 헬퍼.
// 단독 공연 목록/아코디언 펼친 목록 둘 다 재사용
List<Widget> _buildRealSongRows(
    BuildContext context, List<SongEntry> songs, Color ink) {
  return [
    for (var i = 0; i < songs.length; i++) ...[
      if (songs[i].encore && (i == 0 || !songs[i - 1].encore))
        _EncoreDivider(ink: ink),
      Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              (i + 1).toString().padLeft(2, '0'),
              style: TextStyle(
                fontSize: context.sp(11),
                fontWeight: FontWeight.w900,
                color: ink.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                songs[i].name,
                style: TextStyle(
                  fontSize: context.sp(12),
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  ];
}

// [백엔드 수정]
/// 페스티벌 실제 셋리 - 아티스트 이름을 나열해두고, 누른 아티스트만 곡
/// 목록이 펼쳐지는 아코디언(예상 셋리와 동일한 UX). 
/// 한 번에 하나만 펼쳐지고, 목록 순서는 그대로 유지한 채 
/// 펼친 아티스트 위치로 화면 스크롤.
class _RealSetlistGroupedByArtist extends StatefulWidget {
  final List<MapEntry<String?, List<SongEntry>>> groups;
  final Color ink;

  const _RealSetlistGroupedByArtist({required this.groups, this.ink = _kraftInk});

  @override
  State<_RealSetlistGroupedByArtist> createState() =>
      _RealSetlistGroupedByArtistState();
}

class _RealSetlistGroupedByArtistState
    extends State<_RealSetlistGroupedByArtist> {
  int? _expandedIndex;
  late final List<GlobalKey> _sectionKeys = [
    for (var _ in widget.groups) GlobalKey(),
  ];

  void _toggle(int index) {
    final willExpand = _expandedIndex != index;
    setState(() => _expandedIndex = willExpand ? index : null);
    if (!willExpand) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _sectionKeys[index].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var g = 0; g < widget.groups.length; g++)
          Padding(
            key: _sectionKeys[g],
            padding: EdgeInsets.only(
              bottom: g == widget.groups.length - 1 ? 0 : 4,
            ),
            child: _RealSetlistArtistSection(
              artistName: widget.groups[g].key ?? '아티스트 미상',
              songs: widget.groups[g].value,
              expanded: g == _expandedIndex,
              onTap: () => _toggle(g),
              ink: widget.ink,
            ),
          ),
      ],
    );
  }
}

class _RealSetlistArtistSection extends StatelessWidget {
  final String artistName;
  final List<SongEntry> songs;
  final bool expanded;
  final VoidCallback onTap;
  final Color ink;

  const _RealSetlistArtistSection({
    required this.artistName,
    required this.songs,
    required this.expanded,
    required this.onTap,
    this.ink = _kraftInk,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Icon(
                  expanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 16,
                  color: ink.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(
                    artistName,
                    style: TextStyle(
                      fontSize: context.sp(12.5),
                      fontWeight: FontWeight.w900,
                      color: ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2, bottom: 8),
            // [백엔드 수정] songs가 비면 빈 공간 대신 안내 문구 표시.
            child: songs.isEmpty
                ? Text(
                    '아직 채워지지 않았어요',
                    style: TextStyle(
                      fontSize: context.sp(11.5),
                      fontWeight: FontWeight.w600,
                      color: ink.withValues(alpha: 0.5),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildRealSongRows(context, songs, ink),
                  ),
          ),
      ],
    );
  }
}

// [백엔드 수정]
/// 실제 셋리 곡 목록 중 앙코르가 시작되는 지점에 한 번만 표시하는 구분선.
class _EncoreDivider extends StatelessWidget {
  final Color ink;
  const _EncoreDivider({this.ink = _kraftInk});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Container(height: 1, color: ink.withValues(alpha: 0.3)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              'ENCORE',
              style: TextStyle(
                fontSize: context.sp(9.5),
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
                color: ink.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: Container(height: 1, color: ink.withValues(alpha: 0.3)),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ===== 공연 후 "신문 기사" 레이아웃 =====
// 왼쪽 1/3: 제목 + 포스터(제목·공연정보가 차지하고 남은 여백을 채움, 탭하면
// 확대) + 공연 정보. 오른쪽 2/3(가운데+오른쪽 병합, 사이 선 없음): 통째로
// 감상 본문 텍스트박스이고, 그 위에 크기조절/크롭 가능한 사진이 얹혀 텍스트가
// 사진을 피해 실시간으로 둘러싸입니다. 실제 셋 리스트는 오른쪽 아래에 신문
// 광고처럼 고정으로 자리합니다.
// =============================================================================

/// 신문 잉크색/세리프.
const Color _articleInk = Color(0xFF1A1A1A);
const String _articleSerif = 'Georgia';
const List<String> _articleSerifFallback = ['Times New Roman', 'Times', 'serif'];

/// 좁은 왼쪽 단에서 날짜/공연장 같은 값이 글자 단위로 쪼개지지 않도록, 공백
/// (단어) 경계에서만 줄바꿈되게 각 토큰 안에 WORD JOINER(U+2060)를 끼웁니다.
String _keepWords(String text) {
  const wj = '\u{2060}';
  return text.split(' ').map((t) => t.split('').join(wj)).join(' ');
}

TextStyle _articleText(
  BuildContext context, {
  double size = 14,
  FontWeight weight = FontWeight.w400,
  Color color = _articleInk,
  double? height,
  FontStyle? fontStyle,
}) {
  return TextStyle(
    fontFamily: _articleSerif,
    fontFamilyFallback: _articleSerifFallback,
    fontSize: context.sp(size),
    fontWeight: weight,
    color: color,
    height: height,
    fontStyle: fontStyle,
  );
}

// =============================================================================
// ===== 공연 후 "스크랩북" 자유배치 캔버스 =====
// 크래프트 종이 위에 메모지(포스터/공연정보/폴라로이드 사진/실제 셋리스트/
// 공연 후기/타임테이블)를 겹쳐 붙입니다. 빈 곳을 꾹 누르면 편집↔잠금이
// 토글되고, 편집모드에서 각 메모지를 드래그(이동)·두 손가락(확대축소+회전)
// 할 수 있으며, 공연 후기는 더블탭하면 타이핑할 수 있습니다. 배치/크기/회전은
// 서버에 저장하지 않고 세션 동안만 [_scrapStore]에 담아둡니다.
// =============================================================================

const Color _kraftInk = Color(0xFF463C2E);

/// 메모지 색을 하양과 섞어 더 옅게(연하게) 만듭니다.
Color _lighten(Color c, [double factor = 0.72]) {
  return Color.lerp(c, Colors.white, factor)!;
}

/// 공연 제목 글꼴(기본 글꼴).
TextStyle _handTitle(BuildContext context) => TextStyle(
      fontSize: context.sp(24),
      fontWeight: FontWeight.w800,
      color: _kraftInk,
      height: 1.15,
    );

/// 메모지 한 장의 세션 배치 상태. offset은 캔버스 내 절대 위치(좌상단,
/// 회전/확대 적용 전 기준).
class _MemoTransform {
  Offset offset = Offset.zero;
  double scale = 1;
  double rotation = 0;
  bool placed = false; // 기본 위치가 한 번 설정됐는지.

  /// 드래그/확대 시작 시점에 측정해두는 메모지의 실제(배율 1) 크기.
  /// 경계 클램프 계산에 씁니다([_clampToCanvas] 참고).
  Size measuredSize = Size.zero;
}

/// [offset](회전/확대 전 좌상단)에 [scale]/[rotation]을 적용했을 때 메모지가
/// 캔버스([canvasW]×[canvasH]) 밖으로 나가지 않도록 offset을 보정합니다.
///
/// 회전과 확대는 모두 메모지 자신의 중심을 기준으로 적용되므로, 최종 화면상
/// 중심 좌표는 항상 `offset + size/2`와 같습니다. 그 중심을 기준으로 회전된
/// 사각형의 축 정렬 바운딩 박스(AABB) 절반만큼 캔버스 안쪽으로 여유를 두면,
/// 어떤 회전 각도에서도 메모지 전체가 캔버스 경계를 넘지 않습니다.
Offset _clampToCanvas(
  Offset offset,
  double scale,
  double rotation,
  Size size,
  double canvasW,
  double canvasH,
) {
  if (size == Size.zero || canvasW <= 0 || canvasH <= 0) return offset;

  final w = size.width * scale;
  final h = size.height * scale;
  final cosA = math.cos(rotation).abs();
  final sinA = math.sin(rotation).abs();
  final aabbW = w * cosA + h * sinA;
  final aabbH = w * sinA + h * cosA;

  final centerX = offset.dx + size.width / 2;
  final centerY = offset.dy + size.height / 2;

  final minCenterX = aabbW / 2;
  final maxCenterX = canvasW - aabbW / 2;
  final minCenterY = aabbH / 2;
  final maxCenterY = canvasH - aabbH / 2;

  // 메모지가 캔버스보다 커서 범위가 뒤집히면(minCenter > maxCenter),
  // 캔버스 가운데로 고정합니다.
  final clampedCenterX = minCenterX > maxCenterX
      ? canvasW / 2
      : centerX.clamp(minCenterX, maxCenterX);
  final clampedCenterY = minCenterY > maxCenterY
      ? canvasH / 2
      : centerY.clamp(minCenterY, maxCenterY);

  return Offset(
    clampedCenterX - size.width / 2,
    clampedCenterY - size.height / 2,
  );
}

/// ticketId(또는 로컬 키)별 메모 배치. 세션 동안만 유지(앱 재시작 시 초기화).
final Map<String, Map<String, _MemoTransform>> _scrapStore = {};

class _ScrapbookCanvas extends StatefulWidget {
  final String layoutKey;
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final String? reviewText;
  final Future<void> Function(String) onReviewChanged;
  final String? photoUrl;
  final bool uploadingPhoto;
  final Future<void> Function(double)? onAddPhoto;
  final Future<void> Function(String)? onDeletePhoto;
  final String? setlistTicketId;
  final String? concertId;

  const _ScrapbookCanvas({
    required this.layoutKey,
    required this.concertTitle,
    required this.ticketInfo,
    required this.reviewText,
    required this.onReviewChanged,
    required this.photoUrl,
    required this.uploadingPhoto,
    required this.onAddPhoto,
    required this.onDeletePhoto,
    required this.setlistTicketId,
    required this.concertId,
  });

  @override
  State<_ScrapbookCanvas> createState() => _ScrapbookCanvasState();
}

class _ScrapbookCanvasState extends State<_ScrapbookCanvas> {
  bool _edit = false;
  late final TextEditingController _review =
      TextEditingController(text: widget.reviewText ?? '');
  final FocusNode _reviewFocus = FocusNode();
  late final Map<String, _MemoTransform> _t =
      _scrapStore.putIfAbsent(widget.layoutKey, () => {});

  /// 그리는 순서(마지막이 맨 앞). 만진 메모를 앞으로 올립니다.
  final List<String> _z = [
    'poster',
    'info',
    'timetable',
    'setlist',
    'polaroid',
    'review',
  ];

  // 제스처 시작 시점 스냅샷.
  double _startScale = 1;
  double _startRot = 0;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  _MemoTransform _tf(String k) => _t.putIfAbsent(k, () => _MemoTransform());

  /// 메모지별 GlobalKey(경계 클램프를 위한 실제 크기 측정용). 세션 배치와
  /// 달리 이 상태(State) 자신의 생애주기 동안만 유효합니다.
  final Map<String, GlobalKey> _memoKeys = {};
  GlobalKey _keyFor(String k) => _memoKeys.putIfAbsent(k, () => GlobalKey());

  @override
  void initState() {
    super.initState();
    _reviewFocus.addListener(() {
      if (!_reviewFocus.hasFocus) widget.onReviewChanged(_review.text);
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _ScrapbookCanvas old) {
    super.didUpdateWidget(old);
    if (old.reviewText != widget.reviewText &&
        !_reviewFocus.hasFocus &&
        widget.reviewText != _review.text) {
      _review.text = widget.reviewText ?? '';
    }
  }

  @override
  void dispose() {
    _reviewFocus.dispose();
    _review.dispose();
    super.dispose();
  }

  void _toggleMode() {
    setState(() {
      _edit = !_edit;
      if (!_edit) _reviewFocus.unfocus();
    });
  }

  void _bringFront(String k) {
    if (_z.isNotEmpty && _z.last == k) return;
    setState(() {
      _z.remove(k);
      _z.add(k);
    });
  }

  void _placeDefaults(double w, double h) {
    void def(String k, double dx, double dy, double rot) {
      final t = _tf(k);
      if (!t.placed) {
        t.offset = Offset(dx, dy);
        t.rotation = rot;
        t.placed = true;
      }
    }

    // 첨부 스크랩북처럼 살짝 기울여 겹쳐 배치(제목 아래에서 시작). review가
    // 가로 2배(2단, 항상 10줄 고정 높이)로 커서, 세로로 겹치지 않도록
    // 위에서부터 포스터/폴라로이드 → 공연정보/타임테이블 → 후기 → 셋리스트
    // 순으로 단을 나눠 배치합니다(예전엔 후기가 공연정보·타임테이블과 같은
    // 높이에 있어 그 아래 두 메모지를 완전히 덮어 버렸습니다).
    const double reviewTop = 0.52;
    def('poster', w * 0.05, h * 0.03, -0.05);
    def('polaroid', w * 0.54, h * 0.03, 0.06);
    def('info', w * 0.05, h * 0.35, 0.02);
    def('timetable', w * 0.55, h * 0.35, -0.04);
    def('review', w * 0.03, h * reviewTop, -0.01);

    // 후기는 항상 10줄 고정 높이라(요청 이력 참고) 다른 메모지보다 훨씬 큽니다.
    // 셋리스트를 h의 "비율"로 어림잡아 놓으면 기기별 글자 배율에 따라 후기가
    // 셋리스트를 덮어버릴 수 있어, [_reviewBody]와 같은 식으로 실제 높이를
    // 정확히 계산해 그 바로 아래 자리에 놓습니다.
    final reviewHeight = context.sp(12.5) +
        context.rs(6) +
        context.sp(13) * 1.5 * 10 +
        context.rs(11) * 2;
    def('setlist', w * 0.14, h * reviewTop + reviewHeight + context.rs(10), 0.03);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        _placeDefaults(w, h);

        // 후기 메모지 가로 폭: 기존(0.52w)의 2배(1.04w)이되, 캔버스를 넘어
        // 2단 텍스트가 잘리지 않도록 0.94w로 상한.
        final reviewW = w * 1.04 > w * 0.94 ? w * 0.94 : w * 1.04;

        final items = <String, Widget>{
          'poster': _memo(
            'poster',
            baseW: w * 0.42,
            canvasW: w,
            canvasH: h,
            child: _PosterMemo(imageUrl: widget.ticketInfo?.posterImageUrl),
          ),
          'polaroid': _memo(
            'polaroid',
            baseW: w * 0.38,
            canvasW: w,
            canvasH: h,
            child: _PolaroidMemo(
              url: widget.photoUrl,
              uploading: widget.uploadingPhoto,
              onAdd: widget.onAddPhoto,
              onDelete: widget.onDeletePhoto,
            ),
          ),
          'info': _memo(
            'info',
            baseW: w * 0.42,
            canvasW: w,
            canvasH: h,
            child: _InfoNote(
              fields: widget.ticketInfo?.displayFields ?? const [],
              paper: _lighten(const Color(0xFF884000)),
              ink: Colors.black,
            ),
          ),
          'timetable': _memo(
            'timetable',
            baseW: w * 0.44,
            canvasW: w,
            canvasH: h,
            shrinkToContent: true,
            child: _RealTimetableNote(
              concertId: widget.concertId,
              paper: _lighten(const Color(0xFF7A3803)),
              ink: Colors.black,
            ),
          ),
          'setlist': _memo(
            'setlist',
            baseW: w * 0.44,
            canvasW: w,
            canvasH: h,
            child: _SetlistNote(
              ticketId: widget.setlistTicketId,
              paper: _lighten(const Color(0xFF4B382A)),
              ink: Colors.black,
            ),
          ),
          'review': _memo(
            'review',
            baseW: reviewW,
            canvasW: w,
            canvasH: h,
            child: _reviewBody(context),
          ),
        };

        return ClipRect(
          child: Stack(
            children: [
              const Positioned.fill(child: ScrapbookPageBackground()),
              // (2페이지 크래프트 배경 제거) 메모지는 이제 1페이지(카드) 위에
              // 바로 놓입니다 — 배경은 오버레이 카드 색이 그대로 비칩니다.
              // 빈 곳을 꾹 누르면 편집↔잠금 토글(요청4). 탭은 뒤(오버레이의
              // "바깥 탭으로 닫기")로 흘려보내고, 롱프레스만 여기서 처리합니다.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onLongPress: _toggleMode,
                ),
              ),
              // 상단 공연 제목(필기체). 요청1: 메모지가 순서상 제목보다 위에
              // 있어야 하므로(=메모지를 제목 위로 겹쳐 옮길 수 있도록), 제목을
              // 메모지 리스트보다 먼저(뒤에) 그립니다.
              Positioned(
                top: h * 0.015,
                left: w * 0.06,
                right: w * 0.06,
                child: IgnorePointer(
                  child: Text(
                    widget.concertTitle,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _handTitle(context),
                  ),
                ),
              ),
              for (final k in _z)
                if (items[k] != null) items[k]!,
              // 편집/잠금 상태 배지(제목과 겹치지 않게 하단 가운데에).
              Positioned(
                bottom: context.rs(8),
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(child: _ModeBadge(edit: _edit)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 각 메모지: 위치(offset)+회전+배율을 적용하고, 편집모드에선 드래그/두 손가락
  /// 확대축소+회전 제스처를 붙입니다. 공연 후기는 (모드와 무관하게) 더블탭으로
  /// 타이핑 시작. [canvasW]/[canvasH]는 페이지 전체 크기 — 메모지를 페이지
  /// 어디로든 옮길 수 있게 하되, 그 경계 밖으로는 나가지 못하게 막는 데 씁니다.
  /// [shrinkToContent]가 true면 폭을 [baseW]로 고정하지 않고, 내용이 그보다
  /// 좁으면(예: 타임테이블 "미정" 안내 문구) 그 내용 폭에 맞춰 카드(와 테이프)가
  /// 함께 작아집니다 — 내용이 [baseW]보다 넓으면 그대로 [baseW]에서 줄바꿈됩니다.
  Widget _memo(
    String key, {
    required double baseW,
    required double canvasW,
    required double canvasH,
    required Widget child,
    bool shrinkToContent = false,
  }) {
    final t = _tf(key);
    final content = shrinkToContent
        ? ConstrainedBox(
            key: _keyFor(key),
            constraints: BoxConstraints(
              minWidth: context.rs(110),
              maxWidth: baseW,
            ),
            child: IntrinsicWidth(child: child),
          )
        : SizedBox(key: _keyFor(key), width: baseW, child: child);
    final reviewFocused = key == 'review' && _reviewFocus.hasFocus;

    Widget gestured;
    if (reviewFocused) {
      // 타이핑 중엔 TextField가 모든 입력을 받아야 하므로 제스처를 걷어냅니다.
      gestured = content;
    } else if (_edit) {
      gestured = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (d) {
          _bringFront(key);
          _startScale = t.scale;
          _startRot = t.rotation;
          _startOffset = t.offset;
          _startFocal = d.focalPoint;
          // 드래그 시작 시점의 실제(배율 1) 렌더 크기를 측정해둡니다 —
          // 경계 클램프 계산에 필요합니다.
          final box =
              _keyFor(key).currentContext?.findRenderObject() as RenderBox?;
          if (box != null && box.hasSize) t.measuredSize = box.size;
        },
        onScaleUpdate: (d) => setState(() {
          // 한 손가락=이동, 두 손가락=확대축소(scale)+회전(rotation) 동시.
          final rawOffset = _startOffset + (d.focalPoint - _startFocal);
          final newScale = (_startScale * d.scale).clamp(0.4, 3.2);
          final newRotation = _startRot + d.rotation;
          t.scale = newScale;
          t.rotation = newRotation;
          t.offset = _clampToCanvas(
            rawOffset,
            newScale,
            newRotation,
            t.measuredSize,
            canvasW,
            canvasH,
          );
        }),
        onDoubleTap:
            key == 'review' ? () => _reviewFocus.requestFocus() : null,
        child: content,
      );
    } else if (key == 'review') {
      gestured = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => _reviewFocus.requestFocus(),
        // 후기 카드가 커서 캔버스를 많이 덮으므로, 카드를 꾹 눌러도
        // 편집↔잠금이 토글되도록 합니다(빈 곳 롱프레스와 동일).
        onLongPress: _toggleMode,
        child: content,
      );
    } else {
      gestured = content;
    }

    // key가 없으면 _z 재정렬 시 Stack이 인덱스 기준으로 엘리먼트를 재사용해
    // (1) 진행 중인 드래그 제스처가 다른 메모지로 옮겨가고,
    // (2) 셋리스트/타임테이블 State가 파기·재생성되어 재조회됩니다.
    // ValueKey로 메모지 정체성을 고정해 두 문제를 함께 막습니다.
    return Positioned(
      key: ValueKey('memo_$key'),
      left: 0,
      top: 0,
      child: Transform.translate(
        offset: t.offset,
        child: Transform.rotate(
          angle: t.rotation,
          child: Transform.scale(scale: t.scale, child: gestured),
        ),
      ),
    );
  }

  Widget _reviewBody(BuildContext context) {
    const ink = Colors.black; // 요청2: 후기 텍스트 검정.
    final textStyle = _articleText(context, size: 13, height: 1.5, color: ink);
    const maxLinesPerColumn = 10;
    final lineHeight = context.sp(13) * 1.5;
    // 요청3: 세로 크기는 텍스트가 10줄을 다 채웠을 때를 기준으로 고정.
    final columnsHeight = lineHeight * maxLinesPerColumn;

    return _NoteCard(
      tapeColor: const Color(0x66E9D6B4),
      paper: _lighten(const Color(0xFF795C32)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('공연 후기', style: _noteHeader(context, color: ink)),
          SizedBox(height: context.rs(6)),
          SizedBox(
            height: columnsHeight,
            child: _reviewFocus.hasFocus
                ? _buildReviewEditor(context, textStyle)
                : _buildReviewColumns(
                    context, textStyle, maxLinesPerColumn),
          ),
        ],
      ),
    );
  }

  /// 포커스(입력) 상태: 두 단 폭 전체를 채우는 단일 입력창으로 편하게 타이핑.
  /// 입력을 마치면(포커스 해제) [_buildReviewColumns]가 2단으로 다시 흘려 배치.
  Widget _buildReviewEditor(BuildContext context, TextStyle style) {
    return TextField(
      controller: _review,
      focusNode: _reviewFocus,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      cursorColor: Colors.black,
      style: style,
      onTapOutside: (_) => _reviewFocus.unfocus(),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText: '공연 후기를 적어보세요',
        hintStyle: style.copyWith(color: Colors.black.withValues(alpha: 0.4)),
      ),
    );
  }

  /// 잠금(표시) 상태: 왼쪽 단부터 채우고, 10줄을 넘기면 오른쪽 단으로 이어
  /// 흘려 배치합니다(신문 단 나눔). 각 단은 최대 10줄까지만 보여줍니다.
  Widget _buildReviewColumns(
    BuildContext context,
    TextStyle style,
    int maxLines,
  ) {
    final text = _review.text;
    if (text.trim().isEmpty) {
      return Text(
        '공연 후기를 적어보세요\n(더블탭하면 입력)',
        style: style.copyWith(color: Colors.black.withValues(alpha: 0.4)),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final gap = context.rs(12);
        final colW = (c.maxWidth - gap) / 2;
        final split = _splitTextAtLine(text, style, colW, maxLines);
        final left = text.substring(0, split);
        final right = text.substring(split);
        Widget col(String t, TextOverflow of) => SizedBox(
              width: colW,
              child: Text(t, style: style, maxLines: maxLines, overflow: of),
            );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            col(left, TextOverflow.clip),
            SizedBox(width: gap),
            col(right, TextOverflow.ellipsis),
          ],
        );
      },
    );
  }

  /// [width] 폭에서 [maxLines]줄까지 채운 뒤 그 다음 줄이 시작되는 글자
  /// 인덱스(=오른쪽 단 시작점)를 돌려줍니다. 전부 [maxLines] 안에 들어가면
  /// 문자열 길이를 그대로 돌려줍니다(오른쪽 단은 비어 있음).
  int _splitTextAtLine(
    String text,
    TextStyle style,
    double width,
    int maxLines,
  ) {
    if (width <= 0) return text.length;
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    final lines = tp.computeLineMetrics();
    if (lines.length <= maxLines) return text.length;
    final y = lines[maxLines].baseline;
    final pos = tp.getPositionForOffset(Offset(0, y));
    return pos.offset.clamp(0, text.length).toInt();
  }
}

TextStyle _noteHeader(BuildContext context, {Color color = _kraftInk}) =>
    _articleText(
      context,
      size: 12.5,
      weight: FontWeight.w900,
      color: color,
    );

/// 편집/잠금 상태 배지.
class _ModeBadge extends StatelessWidget {
  final bool edit;
  const _ModeBadge({required this.edit});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rs(8),
        vertical: context.rs(4),
      ),
      decoration: BoxDecoration(
        color: (edit ? const Color(0xFF7A6A52) : _kraftInk)
            .withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(edit ? Icons.edit : Icons.lock_outline,
              size: context.rs(12), color: Colors.white),
          SizedBox(width: context.rs(4)),
          Text(
            edit ? '편집 모드' : '잠금 (꾹 눌러 편집)',
            style: TextStyle(
              fontSize: context.sp(10),
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// 메모지 상단 경계선 중앙에 '정중앙'이 오도록 붙는 워시테이프 한 조각.
/// (반드시 `clipBehavior: Clip.none` Stack 안에서, 카드 크기와 같은 폭으로 사용.)
class _WashiTape extends StatelessWidget {
  final Color color;
  const _WashiTape({required this.color});

  @override
  Widget build(BuildContext context) {
    final h = context.rs(15);
    return Positioned(
      // 테이프의 세로 중앙(h/2)이 카드 상단선(y=0)에 오도록 위로 h/2 만큼 올림.
      top: -h / 2,
      left: 0,
      right: 0,
      child: Center(
        child: Transform.rotate(
          angle: -0.04,
          child: Container(
            width: context.rs(46),
            height: h,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// 위에 워시테이프 한 조각을 얹은 종이 메모 카드.
class _NoteCard extends StatelessWidget {
  final Widget child;
  final Color tapeColor;
  final Color paper;

  const _NoteCard({
    required this.child,
    this.tapeColor = const Color(0x66C9B08A),
    this.paper = const Color(0xFFF3ECDD),
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: EdgeInsets.all(context.rs(11)),
          decoration: BoxDecoration(
            color: paper,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 6,
                offset: const Offset(1, 3),
              ),
            ],
          ),
          child: child,
        ),
        _WashiTape(color: tapeColor),
      ],
    );
  }
}

/// 포스터 메모(테이프로 붙인 사진 느낌). 없으면 예시 자리.
class _PosterMemo extends StatelessWidget {
  final String? imageUrl;
  const _PosterMemo({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    final Widget img = (url == null || url.isEmpty)
        ? Container(
            color: Colors.white.withValues(alpha: 0.08),
            alignment: Alignment.center,
            child: Text('POSTER',
                style: _articleText(context,
                    size: 13,
                    weight: FontWeight.w900,
                    color: Colors.black.withValues(alpha: 0.5))),
          )
        : (_isNetworkUrl(url)
            // [백엔드 수정]
            // Image.network -> AppNetworkImage(디스크 캐싱+디코드 크기 축소).
            ? AppNetworkImage(url,
                fit: BoxFit.cover,
                errorBuilder: (c) =>
                    Container(color: Colors.white.withValues(alpha: 0.08)))
            : Image.file(File(url), fit: BoxFit.cover));

    return _NoteCard(
      tapeColor: const Color(0x66B9C4A8),
      paper: _lighten(const Color(0xFF613613)),
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: SizedBox(width: double.infinity, child: img),
      ),
    );
  }
}

/// 폴라로이드 사진 메모(추가/삭제). 사진이 없으면 추가 버튼.
class _PolaroidMemo extends StatelessWidget {
  final String? url;
  final bool uploading;
  final Future<void> Function(double)? onAdd;
  final Future<void> Function(String)? onDelete;

  const _PolaroidMemo({
    required this.url,
    required this.uploading,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final has = url != null && url!.isNotEmpty;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _polaroid(context, has),
        const _WashiTape(color: Color(0x66E9D6B4)),
      ],
    );
  }

  Widget _polaroid(BuildContext context, bool has) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.rs(8),
        context.rs(8),
        context.rs(8),
        context.rs(22), // 폴라로이드 아래쪽 흰 여백.
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 6,
            offset: const Offset(1, 3),
          ),
        ],
      ),
      child: AspectRatio(
        aspectRatio: 1,
        child: has
            ? GestureDetector(
                onLongPress:
                    onDelete == null ? null : () => onDelete!(url!),
                // [백엔드 수정]
                // Image.network -> AppNetworkImage(디스크 캐싱+디코드 크기 축소).
                child: _isNetworkUrl(url!)
                    ? AppNetworkImage(url!,
                        fit: BoxFit.cover,
                        errorBuilder: (c) =>
                            const ColoredBox(color: Color(0x22000000)))
                    : Image.file(File(url!), fit: BoxFit.cover),
              )
            : GestureDetector(
                onTap: uploading ? null : () => onAdd?.call(1.0),
                child: Container(
                  color: const Color(0xFFECE7DD),
                  alignment: Alignment.center,
                  child: uploading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_a_photo_outlined,
                                size: context.rs(22),
                                color: _kraftInk.withValues(alpha: 0.6)),
                            SizedBox(height: context.rs(4)),
                            Text('사진 추가',
                                style: _articleText(context,
                                    size: 10.5,
                                    color: _kraftInk.withValues(alpha: 0.6))),
                          ],
                        ),
                ),
              ),
      ),
    );
  }
}

/// 공연 정보 메모.
class _InfoNote extends StatelessWidget {
  final List<MapEntry<String, String>> fields;
  final Color paper;
  final Color ink;
  const _InfoNote({
    required this.fields,
    this.paper = const Color(0xFFF3ECDD),
    this.ink = _kraftInk,
  });

  @override
  Widget build(BuildContext context) {
    return _NoteCard(
      tapeColor: const Color(0x66E9D6B4),
      paper: paper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('공연 정보', style: _noteHeader(context, color: ink)),
          SizedBox(height: context.rs(6)),
          for (final f in fields)
            Padding(
              padding: EdgeInsets.only(bottom: context.rs(3)),
              child: RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: '${f.key}  ',
                      style: _articleText(context,
                          size: 11,
                          weight: FontWeight.w700,
                          color: ink.withValues(alpha: 0.65)),
                    ),
                    TextSpan(
                      text: _keepWords(f.value),
                      style: _articleText(context,
                          size: 12.5,
                          weight: FontWeight.w600,
                          color: ink),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 실제 셋 리스트 메모.
class _SetlistNote extends StatelessWidget {
  final String? ticketId;
  final Color paper;
  final Color ink;
  const _SetlistNote({
    required this.ticketId,
    this.paper = const Color(0xFFF3ECDD),
    this.ink = _kraftInk,
  });

  @override
  Widget build(BuildContext context) {
    return _NoteCard(
      tapeColor: const Color(0x66E9D6B4),
      paper: paper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('실제 셋 리스트', style: _noteHeader(context, color: ink)),
          SizedBox(height: context.rs(6)),
          _RealSetlistContent(ticketId: ticketId, ink: ink),
        ],
      ),
    );
  }
}

/// 타임테이블 메모(공연 상세 조회). 미등록/조회 전이면 안내.
class _RealTimetableNote extends StatefulWidget {
  final String? concertId;
  final Color paper;
  final Color ink;
  const _RealTimetableNote({
    required this.concertId,
    this.paper = const Color(0xFFF3ECDD),
    this.ink = _kraftInk,
  });

  @override
  State<_RealTimetableNote> createState() => _RealTimetableNoteState();
}

class _RealTimetableNoteState extends State<_RealTimetableNote> {
  final ConcertDetailService _service = ConcertDetailService();
  List<TimetableEntry> _rows = const [];
  String _status = 'loading'; // loading | empty | error | loaded

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.concertId;
    if (id == null) {
      setState(() => _status = 'empty');
      return;
    }
    try {
      final res = await _service.getTimetable(id);
      if (!mounted) return;
      setState(() {
        _rows = res.contents
            .map((e) => TimetableEntry(
                  time: e.time ?? '',
                  label: e.stage != null ? '${e.stage} · ${e.event}' : e.event,
                ))
            .toList();
        _status = _rows.isEmpty ? 'empty' : 'loaded';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _status = e.statusCode == 404 ? 'empty' : 'error');
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = 'error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = widget.ink;
    Widget body;
    if (_status == 'loaded') {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in _rows)
            Padding(
              padding: EdgeInsets.only(bottom: context.rs(3)),
              child: RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: r.time.isEmpty ? '· ' : '${r.time}  ',
                      style: _articleText(context,
                          size: 11.5,
                          weight: FontWeight.w900,
                          color: ink),
                    ),
                    TextSpan(
                      text: _keepWords(r.label),
                      style: _articleText(context,
                          size: 12, color: ink),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    } else {
      body = Text(
        _status == 'loading'
            ? '조회 중'
            : _status == 'error'
                ? '오류'
                : '미정',
        style: _articleText(context,
            size: 12,
            weight: FontWeight.w700,
            color: ink.withValues(alpha: 0.55)),
      );
    }
    return _NoteCard(
      tapeColor: const Color(0x66E9D6B4),
      paper: widget.paper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('타임테이블', style: _noteHeader(context, color: ink)),
          SizedBox(height: context.rs(6)),
          body,
        ],
      ),
    );
  }
}
