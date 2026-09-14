import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kLongPressTimeout, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../models/setlist.dart';
import '../models/ticket_info.dart';
import '../models/timetable.dart' as timetable_model;
import '../services/api_client.dart';
import '../services/concert_detail_service.dart';
import '../services/ticket_service.dart';
import '../services/upload_service.dart';
import 'responsive_text.dart';
import 'concert_envelope.dart';
import 'concert_after_palette.dart';
import 'hanji_texture.dart';
import 'concert_after_ephemera.dart';
import 'concert_after_text_canvas.dart';
import 'app_network_image.dart';

/// 게스트 로그인 상태에서 로컬에 저장된 사진은 절대 파일 경로 문자열이라
/// `http(s)`로 시작하지 않습니다 — 이 차이로 [Image.network]/[Image.file] 중
/// 무엇을 쓸지 결정합니다.
bool _isNetworkUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

// 우표형 포스터 위젯 안에서 실제 포스터 이미지가 차지하는 폭 비율.
const double kConcertAfterPosterImageFillRatio = .80;

// 편집 모드에서 움직일 수 있는 위젯(포스터/사진/봉투)에 더하는 채도 보정값.
const double kConcertAfterEditableWidgetSaturationBoost = .10;

// 텍스트 래핑 시 텍스트와 포스터/사진/봉투 사이에 남기는 최소 간격.
const double kConcertAfterTextWrapHorizontalGap = 3;
const double kConcertAfterTextWrapTopGap = 3;
const double kConcertAfterTextWrapBottomGap = -10;

ColorFilter _saturationFilter(double amount) {
  final inv = 1 - amount;
  final r = .213 * inv;
  final g = .715 * inv;
  final b = .072 * inv;
  return ColorFilter.matrix([
    r + amount,
    g,
    b,
    0,
    0,
    r,
    g + amount,
    b,
    0,
    0,
    r,
    g,
    b + amount,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);
}

Widget _editableWidgetTone({required bool edit, required Widget child}) {
  if (!edit || kConcertAfterEditableWidgetSaturationBoost == 0) return child;
  return ColorFiltered(
    colorFilter: _saturationFilter(
      1 + kConcertAfterEditableWidgetSaturationBoost,
    ),
    child: child,
  );
}

/// 한 장의 공연 후 기록 페이지. 포스터·사진·봉투와 자유 텍스트를 배치합니다.
/// 텍스트는 빈 공간을 더블탭해 추가하고, 메모지와 겹치지 않게 자동 배치됩니다.
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
  Future<timetable_model.TimeTableResponse>? _preloadedTimetable;
  Future<RealSetlistResponse>? _preloadedSetlist;
  String? _preloadedConcertId;
  String? _preloadedTicketId;

  String? get _ticketId => _ticketInfo?.ticketId;

  @override
  void initState() {
    super.initState();
    _preloadLetterData();
  }

  @override
  void didUpdateWidget(covariant ConcertAfterPageContents oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticketInfo != widget.ticketInfo) {
      _ticketInfo = widget.ticketInfo;
      _preloadLetterData();
    }
  }

  void _preloadLetterData() {
    final concertId = _ticketInfo?.concertId;
    final ticketId = _ticketInfo?.ticketId;
    if (_preloadedConcertId != concertId) {
      _preloadedConcertId = concertId;
      _preloadedTimetable = concertId == null
          ? null
          : ConcertDetailService().getTimetable(concertId).catchError((_) {
              return timetable_model.TimeTableResponse(
                id: '',
                concertId: concertId,
                contents: const [],
              );
            });
    }
    if (_preloadedTicketId != ticketId) {
      _preloadedTicketId = ticketId;
      _preloadedSetlist = ticketId == null
          ? null
          : ConcertDetailService().getRealSetlist(ticketId).catchError((_) {
              return RealSetlistResponse(
                concertId: concertId ?? '',
                songs: const [],
                isUserEdited: false,
              );
            });
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
      final updated = await _ticketService.updateTicket(
        _ticketId!,
        review: trimmed,
      );
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
    if ((_ticketInfo?.concertPhotoUrls ?? const <String>[]).length >= 3) {
      _showSnack('사진은 최대 3장까지 첨부할 수 있어요.');
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
        AndroidUiSettings(toolbarTitle: '사진 편집', lockAspectRatio: true),
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

    final canvas = _ScrapbookCanvas(
      layoutKey: _ticketId ?? 'local_after_${widget.concertTitle}',
      concertTitle: widget.concertTitle,
      ticketInfo: _ticketInfo,
      reviewText: _ticketInfo?.review,
      onReviewChanged: _saveReviewInline,
      photoUrls: photoUrls,
      uploadingPhoto: _uploadingPhoto,
      onAddPhoto: _uploadingPhoto ? null : _addPhoto,
      onDeletePhoto: _uploadingPhoto ? null : _confirmDeletePhoto,
      setlistTicketId: _ticketId,
      concertId: _ticketInfo?.concertId,
      initialTimetableLoad: _preloadedTimetable,
      initialSetlistLoad: _preloadedSetlist,
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
  final Future<RealSetlistResponse>? initialLoad;

  const _RealSetlistContent({
    required this.ticketId,
    this.ink = _kraftInk,
    this.initialLoad,
  });

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
      final res =
          await (widget.initialLoad ?? _service.getRealSetlist(ticketId));
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
      final only = allArtists.isEmpty
          ? songs
          : songsByArtist[allArtists.first]!;
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
        MapEntry<String?, List<SongEntry>>(
          name,
          songsByArtist[name] ?? const [],
        ),
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
  BuildContext context,
  List<SongEntry> songs,
  Color ink,
) {
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

  const _RealSetlistGroupedByArtist({
    required this.groups,
    this.ink = _kraftInk,
  });

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
const List<String> _articleSerifFallback = [
  'Times New Roman',
  'Times',
  'serif',
];

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
// 공연 후기/타임테이블)를 겹쳐 붙입니다. 페이지 안쪽 어디를 꾹 누르면
// 편집↔잠금이 토글되고, 편집모드에서 각 메모지를 드래그(이동)·두 손가락(확대축소+회전)
// 할 수 있으며, 공연 후기는 더블탭하면 타이핑할 수 있습니다. 배치/크기/회전은
// 서버에 저장하지 않고 세션 동안만 [_scrapStore]에 담아둡니다.
// =============================================================================

const Color _kraftInk = Color(0xFF463C2E);

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
  double canvasH, {
  double minTop = 0,
}) {
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
  final minCenterY = minTop + aabbH / 2;
  final maxCenterY = canvasH - aabbH / 2;

  // 메모지가 캔버스보다 커서 범위가 뒤집히면(minCenter > maxCenter),
  // 캔버스 가운데로 고정합니다.
  final clampedCenterX = minCenterX > maxCenterX
      ? canvasW / 2
      : centerX.clamp(minCenterX, maxCenterX);
  final clampedCenterY = minCenterY > maxCenterY
      ? minTop + (canvasH - minTop) / 2
      : centerY.clamp(minCenterY, maxCenterY);

  return Offset(
    clampedCenterX - size.width / 2,
    clampedCenterY - size.height / 2,
  );
}

double _clampMemoScaleToCanvas(
  double scale,
  double rotation,
  Size size,
  double canvasW,
  double canvasH, {
  double minTop = 0,
}) {
  if (size == Size.zero || canvasW <= 0 || canvasH <= minTop) return scale;
  final cosA = math.cos(rotation).abs();
  final sinA = math.sin(rotation).abs();
  final unitAabbW = size.width * cosA + size.height * sinA;
  final unitAabbH = size.width * sinA + size.height * cosA;
  final maxScaleW = unitAabbW <= 0 ? scale : canvasW / unitAabbW;
  final maxScaleH = unitAabbH <= 0 ? scale : (canvasH - minTop) / unitAabbH;
  return scale
      .clamp(0.4, math.min(3.2, math.min(maxScaleW, maxScaleH)))
      .toDouble();
}

/// ticketId(또는 로컬 키)별 메모 배치. 세션 동안만 유지(앱 재시작 시 초기화).
final Map<String, Map<String, _MemoTransform>> _scrapStore = {};

class _ScrapbookCanvas extends StatefulWidget {
  final String layoutKey;
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final String? reviewText;
  final Future<void> Function(String) onReviewChanged;
  final List<String> photoUrls;
  final bool uploadingPhoto;
  final Future<void> Function(double)? onAddPhoto;
  final Future<void> Function(String)? onDeletePhoto;
  final String? setlistTicketId;
  final String? concertId;
  final Future<timetable_model.TimeTableResponse>? initialTimetableLoad;
  final Future<RealSetlistResponse>? initialSetlistLoad;

  const _ScrapbookCanvas({
    required this.layoutKey,
    required this.concertTitle,
    required this.ticketInfo,
    required this.reviewText,
    required this.onReviewChanged,
    required this.photoUrls,
    required this.uploadingPhoto,
    required this.onAddPhoto,
    required this.onDeletePhoto,
    required this.setlistTicketId,
    required this.concertId,
    required this.initialTimetableLoad,
    required this.initialSetlistLoad,
  });

  @override
  State<_ScrapbookCanvas> createState() => _ScrapbookCanvasState();
}

class _ScrapbookCanvasState extends State<_ScrapbookCanvas> {
  Color? _posterAccent;
  PosterMood? _posterMood;

  Color get _envelopeColor {
    if (kConcertAfterPosterMoodEnabled && _posterMood != null) {
      return _posterMood!.materialColor;
    }
    final base = HSVColor.fromColor(
      _posterAccent ??
          _fallbackPosterAccentColor(widget.ticketInfo?.posterImageUrl),
    );
    return concertAfterTone(
      hue: base.hue,
      saturation: (base.saturation * .28 + .07).clamp(.06, .36),
      value: (.84 + (base.value - .5) * .06).clamp(.73, .94),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadEnvelopeAccent();
  }

  @override
  void didUpdateWidget(covariant _ScrapbookCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticketInfo?.posterImageUrl !=
        widget.ticketInfo?.posterImageUrl) {
      _loadEnvelopeAccent();
    }
  }

  void _loadEnvelopeAccent() {
    _posterAccent = null;
    _posterMood = null;
    final key = widget.ticketInfo?.posterImageUrl;
    if (key == null || key.isEmpty) return;
    unawaited(
      _extractPosterMood(key)
          .then((mood) {
            if (!mounted || widget.ticketInfo?.posterImageUrl != key) return;
            setState(() {
              _posterAccent = mood.accent;
              _posterMood = mood;
            });
          })
          .catchError((_) {}),
    );
  }

  final _textCanvasKey = GlobalKey<ConcertAfterTextCanvasState>();
  bool _edit = false;
  Timer? _pageLongPressTimer;
  Offset? _pageLongPressDownPosition;
  late final Map<String, _MemoTransform> _t = _scrapStore.putIfAbsent(
    widget.layoutKey,
    () => {},
  );

  /// 그리는 순서(마지막이 맨 앞). 만진 메모를 앞으로 올립니다.
  final List<String> _z = [
    'poster',
    'envelope',
    'polaroid',
    'photo_2',
    'photo_3',
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
  void dispose() {
    _cancelPageLongPress();
    super.dispose();
  }

  void _startPageLongPress(Offset position) {
    _cancelPageLongPress();
    if (_edit &&
        (_textCanvasKey.currentState?.containsTextAt(position) ?? false)) {
      return;
    }
    if (_letterOpen) return;
    _pageLongPressDownPosition = position;
    _pageLongPressTimer = Timer(kLongPressTimeout, () {
      if (!mounted) return;
      _pageLongPressTimer = null;
      _pageLongPressDownPosition = null;
      _toggleMode();
    });
  }

  void _maybeCancelPageLongPress(Offset position) {
    final down = _pageLongPressDownPosition;
    if (down == null) return;
    if ((position - down).distance > kTouchSlop) _cancelPageLongPress();
  }

  void _cancelPageLongPress() {
    _pageLongPressTimer?.cancel();
    _pageLongPressTimer = null;
    _pageLongPressDownPosition = null;
  }

  void _toggleMode() {
    setState(() {
      _edit = !_edit;
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  void _bringFront(String k) {
    if (_z.isNotEmpty && _z.last == k) return;
    setState(() {
      _z.remove(k);
      _z.add(k);
    });
  }

  double _titleSafeBottom(double width) {
    final painter = TextPainter(
      text: TextSpan(text: widget.concertTitle, style: _handTitle(context)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, width - 40));
    final bottom = 16 + painter.height + 10;
    painter.dispose();
    return bottom;
  }

  void _placeDefaults(double w, double h, double titleSafeBottom) {
    void def(String k, double dx, double dy, double rot) {
      final t = _tf(k);
      if (!t.placed) {
        t.offset = Offset(dx, dy);
        t.rotation = rot;
        t.placed = true;
      }
    }

    def('poster', w * 0.05, titleSafeBottom + 12, -0.05);
    def('polaroid', w * 0.54, titleSafeBottom + 12, 0.06);
    def('envelope', w * 0.32, h * 0.34, -0.08);
    def('photo_2', w * 0.06, h * 0.58, -0.04);
    def('photo_3', w * 0.55, h * 0.64, 0.04);
  }

  bool _letterOpen = false;

  Future<void> _openLetter() async {
    if (_letterOpen) return;
    _cancelPageLongPress();
    final timetableFuture = widget.initialTimetableLoad;
    final setlistFuture = widget.initialSetlistLoad;
    final box =
        _keyFor('envelope').currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final source = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    setState(() => _letterOpen = true);
    await showConcertLetter(
      context: context,
      source: source,
      envelopeColor: _envelopeColor,
      columns: [
        _LetterColumn(
          title: '공연 정보',
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final field
                    in widget.ticketInfo?.displayFields ??
                        <MapEntry<String, String>>[])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          field.key,
                          style: const TextStyle(
                            fontSize: 11,
                            color: _kraftInk,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          field.value,
                          style: const TextStyle(fontSize: 13, height: 1.5),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        _LetterColumn(
          title: '타임테이블',
          child: SingleChildScrollView(
            child: _RealTimetableNote(
              concertId: widget.concertId,
              ink: _kraftInk,
              initialLoad: timetableFuture,
            ),
          ),
        ),
        _LetterColumn(
          title: '실제 셋 리스트',
          child: _RealSetlistContent(
            ticketId: widget.setlistTicketId,
            ink: _kraftInk,
            initialLoad: setlistFuture,
          ),
        ),
      ],
    );
    if (mounted) setState(() => _letterOpen = false);
  }

  double _memoBaseWidth(String key, double width) => switch (key) {
    'poster' => width * .21,
    'polaroid' => width * .266,
    'photo_2' => width * .266 * 4 / 3,
    'photo_3' => width * .266,
    'envelope' => width * .288,
    _ => width * .26,
  };

  double _photoAspectRatio(int index) => switch (index) {
    0 => 1,
    1 => 4 / 3,
    _ => 3 / 4,
  };

  double _memoAspectRatio(String key) => switch (key) {
    'poster' => 3 / 4,
    'envelope' => 1.55,
    'photo_2' => 4 / 3,
    'photo_3' => 3 / 4,
    'polaroid' => 1,
    _ => 1,
  };

  Size _memoFallbackSize(String key, double width) {
    final fallbackW = _memoBaseWidth(key, width);
    return Size(fallbackW, fallbackW / _memoAspectRatio(key));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        final titleSafeBottom = _titleSafeBottom(w);
        _placeDefaults(w, h, titleSafeBottom);
        _clampPlacedMemos(w, h, titleSafeBottom);

        final items = <String, Widget>{
          'poster': _memo(
            'poster',
            baseW: _memoBaseWidth('poster', w),
            canvasW: w,
            canvasH: h,
            titleSafeBottom: titleSafeBottom,
            child: _editableWidgetTone(
              edit: _edit,
              child: _PosterMemo(
                imageUrl: widget.ticketInfo?.posterImageUrl,
                paperColor: _envelopeColor,
              ),
            ),
          ),
          for (var index = 0; index < 3; index++)
            (index == 0 ? 'polaroid' : 'photo_${index + 1}'): _memo(
              index == 0 ? 'polaroid' : 'photo_${index + 1}',
              baseW: _memoBaseWidth(
                index == 0 ? 'polaroid' : 'photo_${index + 1}',
                w,
              ),
              canvasW: w,
              canvasH: h,
              titleSafeBottom: titleSafeBottom,
              child: _editableWidgetTone(
                edit: _edit,
                child: _PolaroidMemo(
                  aspectRatio: _photoAspectRatio(index),
                  url: index < widget.photoUrls.length
                      ? widget.photoUrls[index]
                      : null,
                  edit: _edit,
                  uploading: widget.uploadingPhoto,
                  onAdd: widget.onAddPhoto,
                  onDelete: widget.onDeletePhoto,
                ),
              ),
            ),
          'envelope': _memo(
            'envelope',
            baseW: _memoBaseWidth('envelope', w),
            canvasW: w,
            canvasH: h,
            titleSafeBottom: titleSafeBottom,
            child: Opacity(
              opacity: _letterOpen ? 0 : 1,
              child: _editableWidgetTone(
                edit: _edit,
                child: ConcertEnvelope(
                  onTap: _openLetter,
                  idleFlutter: !_edit && !_letterOpen,
                  showBodyShadow: _edit,
                  color: _envelopeColor,
                ),
              ),
            ),
          ),
        };

        return ClipRect(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) => _startPageLongPress(event.position),
            onPointerMove: (event) => _maybeCancelPageLongPress(event.position),
            onPointerUp: (_) => _cancelPageLongPress(),
            onPointerCancel: (_) => _cancelPageLongPress(),
            child: Stack(
              children: [
                PosterMoodScope(
                  mood: _posterMood,
                  child: ConcertAfterTextCanvas(
                    key: _textCanvasKey,
                    storageKey: widget.layoutKey,
                    initialReview: widget.reviewText ?? '',
                    width: w,
                    minHeight: h,
                    minContentTop: titleSafeBottom,
                    editMode: _edit,
                    obstacles: _obstacles(w, titleSafeBottom),
                    backgroundOverlays: [
                      _AfterDecorativeBoxes(
                        seedKey:
                            '${widget.layoutKey}_${widget.ticketInfo?.posterImageUrl ?? ''}',
                        posterKey: widget.ticketInfo?.posterImageUrl,
                        contentTop: titleSafeBottom,
                        width: w,
                        height: h,
                      ),
                    ],
                    onReviewChanged: widget.onReviewChanged,
                    memos: [
                      Positioned(
                        top: 16,
                        left: 20,
                        right: 20,
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
                    ],
                  ),
                ),
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
          ),
        );
      },
    );
  }

  void _clampPlacedMemos(
    double canvasW,
    double canvasH,
    double titleSafeBottom,
  ) {
    for (final key in _z) {
      final t = _tf(key);
      final size = t.measuredSize == Size.zero
          ? _memoFallbackSize(key, canvasW)
          : t.measuredSize;
      t.scale = _clampMemoScaleToCanvas(
        t.scale,
        t.rotation,
        size,
        canvasW,
        canvasH,
        minTop: titleSafeBottom,
      );
      t.offset = _clampToCanvas(
        t.offset,
        t.scale,
        t.rotation,
        size,
        canvasW,
        canvasH,
        minTop: titleSafeBottom,
      );
    }
  }

  /// 메모지의 이동·회전·확대 제스처. 실제 변환 경계는 텍스트 배치에도 사용합니다.
  Widget _memo(
    String key, {
    required double baseW,
    required double canvasW,
    required double canvasH,
    required Widget child,
    required double titleSafeBottom,
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
    Widget gestured;
    if (_edit) {
      gestured = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: key == 'envelope' ? _openLetter : null,
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
          final newRotation = _startRot + d.rotation;
          final newScale = _clampMemoScaleToCanvas(
            _startScale * d.scale,
            newRotation,
            t.measuredSize,
            canvasW,
            canvasH,
            minTop: titleSafeBottom,
          );
          t.scale = newScale;
          t.rotation = newRotation;
          t.offset = _clampToCanvas(
            rawOffset,
            newScale,
            newRotation,
            t.measuredSize,
            canvasW,
            canvasH,
            minTop: titleSafeBottom,
          );
        }),
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

  List<Rect> _obstacles(double width, double titleSafeBottom) {
    final result = <Rect>[Rect.fromLTWH(0, 0, width, titleSafeBottom)];
    var needsMeasure = false;
    for (final key in _z) {
      final t = _tf(key);
      final box = _keyFor(key).currentContext?.findRenderObject() as RenderBox?;
      final measured = box != null && box.hasSize
          ? box.size
          : _memoFallbackSize(key, width);
      if (t.measuredSize != measured) {
        t.measuredSize = measured;
        needsMeasure = true;
      }
      final bounds = MatrixUtils.transformRect(
        Matrix4.identity()
          ..translateByDouble(
            t.offset.dx + measured.width / 2,
            t.offset.dy + measured.height / 2,
            0,
            1,
          )
          ..rotateZ(t.rotation)
          ..scaleByDouble(t.scale, t.scale, 1, 1)
          ..translateByDouble(-measured.width / 2, -measured.height / 2, 0, 1),
        Offset.zero & measured,
      );
      final obstacleBottom = math.max(
        bounds.top,
        bounds.bottom + kConcertAfterTextWrapBottomGap,
      );
      result.add(
        Rect.fromLTRB(
          bounds.left - kConcertAfterTextWrapHorizontalGap,
          bounds.top - kConcertAfterTextWrapTopGap,
          bounds.right + kConcertAfterTextWrapHorizontalGap,
          obstacleBottom,
        ),
      );
    }
    if (needsMeasure) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    return result;
  }
}

int _stableSeed(String value) {
  var hash = 0x811C9DC5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

Color _fallbackPosterAccentColor(String? posterKey) {
  if (posterKey == null || posterKey.isEmpty) return const Color(0xFF8A5D3B);
  final seed = _stableSeed(posterKey);
  return HSVColor.fromAHSV(
    1,
    (seed % 360).toDouble(),
    .42 + ((seed >> 8) % 20) / 100,
    .58 + ((seed >> 16) % 18) / 100,
  ).toColor();
}

Future<Color> _extractPosterAccentColor(String posterKey) async =>
    (await _extractPosterMood(posterKey)).accent;

// 동일 포스터는 페이지/네모상자에서 한 번만 분석한다. 최근 12개만 보관한다.
final _posterMoodCache = <String, Future<PosterMood>>{};
Future<PosterMood> _extractPosterMood(String posterKey) {
  final cached = _posterMoodCache[posterKey];
  if (cached != null) return cached;
  if (_posterMoodCache.length >= 12) {
    _posterMoodCache.remove(_posterMoodCache.keys.first);
  }
  final pending = _analyzePosterMood(posterKey);
  _posterMoodCache[posterKey] = pending;
  return pending;
}

Future<PosterMood> _analyzePosterMood(String posterKey) async {
  final provider = _isNetworkUrl(posterKey)
      ? NetworkImage(posterKey)
      : FileImage(File(posterKey)) as ImageProvider;
  final stream = provider.resolve(const ImageConfiguration());
  final completer = Completer<ui.Image>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!completer.isCompleted) completer.complete(info.image);
      stream.removeListener(listener);
    },
    onError: (error, stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  final image = await completer.future.timeout(const Duration(seconds: 2));
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) throw StateError("Poster pixels unavailable");
  final data = bytes.buffer.asUint8List();
  final buckets = <int, ({int count, int r, int g, int b})>{};
  final stepX = math.max(1, image.width ~/ 36);
  final stepY = math.max(1, image.height ~/ 36);
  double sat = 0, value = 0, lum = 0, lum2 = 0, detail = 0;
  int samples = 0;
  for (var y = 0; y < image.height; y += stepY) {
    for (var x = 0; x < image.width; x += stepX) {
      final i = (y * image.width + x) * 4;
      if (i + 3 >= data.length) continue;
      final r = data[i];
      final g = data[i + 1];
      final b = data[i + 2];
      final a = data[i + 3];
      if (a < 180) continue;
      final hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
      sat += hsv.saturation;
      value += hsv.value;
      final l = (.213 * r + .715 * g + .072 * b) / 255;
      lum += l;
      lum2 += l * l;
      samples++;
      if (x + 1 < image.width && data[i + 7] >= 180) {
        final neighbor =
            (.213 * data[i + 4] + .715 * data[i + 5] + .072 * data[i + 6]) /
            255;
        detail += (l - neighbor).abs();
      }
      if (hsv.saturation < .18 || hsv.value < .18 || hsv.value > .96) continue;
      final key =
          ((hsv.hue / 24).floor() << 8) |
          ((hsv.saturation * 4).floor() << 4) |
          (hsv.value * 4).floor();
      final old = buckets[key];
      buckets[key] = (
        count: (old?.count ?? 0) + 1,
        r: (old?.r ?? 0) + r,
        g: (old?.g ?? 0) + g,
        b: (old?.b ?? 0) + b,
      );
    }
  }
  final best = buckets.isEmpty
      ? null
      : buckets.values.reduce((a, b) => a.count >= b.count ? a : b);
  final accent = best == null
      ? (samples == 0
            ? _fallbackPosterAccentColor(posterKey)
            : HSVColor.fromAHSV(1, 0, 0, value / samples).toColor())
      : Color.fromARGB(
          255,
          (best.r / best.count).round(),
          (best.g / best.count).round(),
          (best.b / best.count).round(),
        );
  final n = math.max(1, samples);
  return PosterMood(
    accent,
    sat / n,
    value / n,
    math.sqrt(math.max(0, lum2 / n - math.pow(lum / n, 2))),
    detail / n,
  );
}

class _AfterDecorativeBoxes extends StatefulWidget {
  final String seedKey;
  final String? posterKey;
  final double width;
  final double height;
  final double contentTop;

  const _AfterDecorativeBoxes({
    required this.seedKey,
    required this.posterKey,
    required this.width,
    required this.height,
    required this.contentTop,
  });

  @override
  State<_AfterDecorativeBoxes> createState() => _AfterDecorativeBoxesState();
}

class _AfterDecorativeBoxesState extends State<_AfterDecorativeBoxes> {
  Color? _extractedColor;
  String? _loadingPosterKey;

  @override
  void initState() {
    super.initState();
    _loadColor();
  }

  @override
  void didUpdateWidget(covariant _AfterDecorativeBoxes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.posterKey != widget.posterKey) _loadColor();
  }

  void _loadColor() {
    final key = widget.posterKey;
    _extractedColor = null;
    _loadingPosterKey = key;
    if (key == null || key.isEmpty) return;
    unawaited(
      _extractPosterAccentColor(key)
          .then((color) {
            if (!mounted || _loadingPosterKey != key) return;
            setState(() => _extractedColor = color);
          })
          .catchError((_) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mood = PosterMoodScope.of(context);
    final rnd = math.Random(_stableSeed(widget.seedKey));
    final base = HSVColor.fromColor(
      mood?.accent ??
          _extractedColor ??
          _fallbackPosterAccentColor(widget.posterKey),
    );
    // 네모박스는 제목을 포함한 전체 페이지의 중앙 98%에 배치한다.
    final contentTop = widget.contentTop.clamp(0.0, widget.height);
    final contentHeight = math.max(0.0, widget.height - contentTop);
    final edgeX = widget.width * .01;
    final edgeY = widget.height * .01;
    final usableW = widget.width * .98;
    final usableH = widget.height * .98;
    if (usableW <= 0 || usableH <= 0) {
      return const Positioned.fill(child: SizedBox.shrink());
    }

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < 3; i++)
              _decorativeBox(i, rnd, base, edgeX, edgeY, usableW, usableH),
            Positioned(
              left: edgeX,
              top: contentTop + contentHeight * .01,
              width: usableW,
              height: contentHeight * .98,
              child: ConcertAfterEphemera(
                base: HSVColor.fromColor(
                  mood?.paperColor ?? concertAfterTone(hue: 42),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _decorativeBox(
    int index,
    math.Random rnd,
    HSVColor base,
    double edgeX,
    double edgeY,
    double usableW,
    double usableH,
  ) {
    final mood = PosterMoodScope.of(context);
    // 작은 본문에서도 상자 전체가 여백 안에 들어가도록 축소한다.
    final boxW = math.min(widget.width * (.5 + rnd.nextDouble() * .2), usableW);
    final boxH = math.min(
      widget.height * (.5 + rnd.nextDouble() * .2),
      usableH,
    );
    final dx = edgeX + rnd.nextDouble() * (usableW - boxW);
    final dy = edgeY + rnd.nextDouble() * (usableH - boxH);
    const hueOffsets = [-20.0, 0.0, 20.0];
    final hue = (base.hue + hueOffsets[index % hueOffsets.length]) % 360;
    // 포스터 색조를 유지하되 바랜 염색 종이의 채도/명도로 압축한다.
    final saturationOffset = (rnd.nextDouble() - .5) * .06;
    const paperValues = [.82, .88, .76, .90, .84];
    final color = concertAfterTone(
      hue: hue,
      alpha: kConcertAfterDecorationAlpha,
      saturation:
          ((mood?.paperSaturation ?? (base.saturation * .28 + .07)) +
                  saturationOffset)
              .clamp(.06, .36),
      value:
          (mood == null
                  ? paperValues[index % paperValues.length] +
                        (base.value - .5) * .06
                  : mood.paperValue +
                        (paperValues[index % paperValues.length] - .84) *
                            (.5 + mood.contrast))
              .clamp(.73, .94),
    );
    return Positioned(
      left: dx,
      top: dy,
      width: boxW,
      height: boxH,
      child: ClipRect(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _SubtleBoxNoisePainter(
              seed: rnd.nextInt(1 << 31),
              color: color,
              textureOpacity: mood?.textureOpacity ?? kHanjiTextureOpacity,
            ),
          ),
        ),
      ),
    );
  }
}

class _SubtleBoxNoisePainter extends CustomPainter {
  final int seed;
  final Color color;
  final double textureOpacity;
  const _SubtleBoxNoisePainter({
    required this.seed,
    required this.color,
    this.textureOpacity = kHanjiTextureOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final edgeRandom = math.Random(seed);
    final paper = Path();
    // 미세하게 불규칙한 종이 재단면.
    final corners = [
      const Offset(1, 1),
      Offset(size.width - 1, 1),
      Offset(size.width - 1, size.height - 1),
      Offset(1, size.height - 1),
    ];
    paper.moveTo(1, 1);
    for (var side = 0; side < 4; side++) {
      final start = corners[side];
      final end = corners[(side + 1) % 4];
      final steps = ((end - start).distance / 4).ceil().clamp(1, 1000);
      for (var step = 1; step <= steps; step++) {
        final point = Offset.lerp(start, end, step / steps)!;
        final jitter = (edgeRandom.nextDouble() - .5) * 1.4;
        paper.lineTo(
          point.dx + (side.isOdd ? jitter : 0),
          point.dy + (side.isEven ? jitter : 0),
        );
      }
    }
    paper.close();
    canvas.drawShadow(
      paper,
      const Color(0xFF403327).withValues(alpha: .12),
      1,
      false,
    );
    canvas.save();
    canvas.clipPath(paper);
    canvas.drawColor(color, BlendMode.srcOver);
    HanjiTexturePainter(
      seed: seed,
      opacity: textureOpacity,
    ).paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SubtleBoxNoisePainter oldDelegate) =>
      seed != oldDelegate.seed ||
      color != oldDelegate.color ||
      textureOpacity != oldDelegate.textureOpacity;
}

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
        color: (edit ? const Color(0xFF7A6A52) : _kraftInk).withValues(
          alpha: 0.85,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            edit ? Icons.edit : Icons.lock_outline,
            size: context.rs(12),
            color: Colors.white,
          ),
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
class _PosterMemo extends StatelessWidget {
  final String? imageUrl;
  final Color paperColor;
  const _PosterMemo({required this.imageUrl, required this.paperColor});

  void _showPosterPreview(BuildContext context, Widget poster) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '포스터 닫기',
      barrierColor: Colors.black.withValues(alpha: .62),
      pageBuilder: (context, animation, secondaryAnimation) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: HeroMode(
                enabled: false,
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .35),
                          blurRadius: 28,
                          offset: const Offset(0, 16),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: poster,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final t = Curves.easeOutCubic.transform(animation.value);
        return Opacity(
          opacity: t,
          child: Transform.scale(scale: .92 + .08 * t, child: child),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    final Widget img = (url == null || url.isEmpty)
        ? Container(
            color: Colors.white.withValues(alpha: 0.08),
            alignment: Alignment.center,
            child: Text(
              'POSTER',
              style: _articleText(
                context,
                size: 13,
                weight: FontWeight.w900,
                color: Colors.black.withValues(alpha: 0.5),
              ),
            ),
          )
        : (_isNetworkUrl(url)
              // [백엔드 수정]
              // Image.network -> AppNetworkImage(디스크 캐싱+디코드 크기 축소).
              ? AppNetworkImage(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (c) =>
                      Container(color: Colors.white.withValues(alpha: 0.08)),
                )
              : Image.file(File(url), fit: BoxFit.cover));

    return GestureDetector(
      onDoubleTap: () => _showPosterPreview(context, img),
      child: _PostagePosterFrame(
        paperColor: paperColor,
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: SizedBox(
            width: double.infinity,
            child: _PaperImageEffect(child: img),
          ),
        ),
      ),
    );
  }
}

class _PostagePosterFrame extends StatelessWidget {
  final Widget child;
  final Color paperColor;
  const _PostagePosterFrame({required this.child, required this.paperColor});

  @override
  Widget build(BuildContext context) {
    final perforation = context.rs(6);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 0;
        final padding = width <= 0
            ? perforation
            : width * (1 - kConcertAfterPosterImageFillRatio) / 2;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            CustomPaint(
              painter: _PostagePosterPainter(
                perforation: perforation,
                paperColor: paperColor,
              ),
              child: Padding(
                padding: EdgeInsets.all(math.max(perforation * .55, padding)),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: paperColor),
                  child: ClipRect(child: child),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PostagePosterPainter extends CustomPainter {
  final double perforation;
  final Color paperColor;
  const _PostagePosterPainter({
    required this.perforation,
    required this.paperColor,
  });

  Path _stampPath(Size size) => Path()..addRect(Offset.zero & size);

  void _forEachPerforation(
    Size size,
    void Function(Offset center, double r) f,
  ) {
    final rect = Offset.zero & size;
    final r = perforation * .56;
    final gap = perforation * 2.08;
    for (var x = gap / 2; x < size.width; x += gap) {
      f(Offset(x, rect.top), r);
      f(Offset(x, rect.bottom), r);
    }
    for (var y = gap / 2; y < size.height; y += gap) {
      f(Offset(rect.left, y), r);
      f(Offset(rect.right, y), r);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final stamp = _stampPath(size);
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawPath(
      stamp.shift(const Offset(1.5, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: .12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawPath(stamp, Paint()..color = paperColor);
    canvas.save();
    canvas.clipPath(stamp);
    const HanjiTexturePainter().paint(canvas, size);
    canvas.restore();
    final clearPaint = Paint()..blendMode = BlendMode.clear;
    _forEachPerforation(size, (center, r) {
      canvas.drawCircle(center, r, clearPaint);
    });
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PostagePosterPainter oldDelegate) =>
      perforation != oldDelegate.perforation ||
      paperColor != oldDelegate.paperColor;
}

/// 바랜 종이 인쇄: 채도와 대비를 낮추고 검정을 들어 올린다.
/// 원본 파일은 유지하며 포스터와 사진에 동일한 보정을 적용한다.
class _PaperImageEffect extends StatelessWidget {
  final Widget child;
  const _PaperImageEffect({required this.child});

  @override
  Widget build(BuildContext context) => ClipRect(
    child: HanjiTexture(
      opacity:
          PosterMoodScope.of(context)?.textureOpacity ?? kHanjiTextureOpacity,
      child: ColorFiltered(
        colorFilter:
            PosterMoodScope.of(context)?.imageFilter ??
            const ColorFilter.matrix([
              .361,
              .322,
              .033,
              0,
              53,
              .096,
              .587,
              .033,
              0,
              50,
              .096,
              .322,
              .298,
              0,
              44,
              0,
              0,
              0,
              1,
              0,
            ]),
        child: child,
      ),
    ),
  );
}

/// 사진 슬롯. 각 슬롯의 표시 비율과 업로드 크롭 비율을 함께 맞춘다.
class _PolaroidMemo extends StatelessWidget {
  final double aspectRatio;
  final String? url;
  final bool edit;
  final bool uploading;
  final Future<void> Function(double)? onAdd;
  final Future<void> Function(String)? onDelete;

  const _PolaroidMemo({
    required this.aspectRatio,
    required this.url,
    required this.edit,
    required this.uploading,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final has = url != null && url!.isNotEmpty;
    return _photo(context, has);
  }

  Widget _photo(BuildContext context, bool has) {
    return Container(
      decoration: BoxDecoration(
        color: concertAfterTone(hue: 42),
        boxShadow: edit
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 6,
                  offset: const Offset(1, 3),
                ),
              ]
            : null,
      ),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: has
            ? GestureDetector(
                onLongPress: edit
                    ? (onDelete == null ? null : () => onDelete!(url!))
                    : null,
                // [백엔드 수정]
                // Image.network -> AppNetworkImage(디스크 캐싱+디코드 크기 축소).
                child: _PaperImageEffect(
                  child: _isNetworkUrl(url!)
                      ? AppNetworkImage(
                          url!,
                          fit: BoxFit.cover,
                          errorBuilder: (c) =>
                              const ColoredBox(color: Color(0x22000000)),
                        )
                      : Image.file(File(url!), fit: BoxFit.cover),
                ),
              )
            : GestureDetector(
                onTap: uploading ? null : () => onAdd?.call(aspectRatio),
                child: Container(
                  color: concertAfterTone(hue: 42),
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
                            Icon(
                              Icons.add_a_photo_outlined,
                              size: context.rs(22),
                              color: _kraftInk.withValues(alpha: 0.6),
                            ),
                            SizedBox(height: context.rs(4)),
                            Text(
                              '사진 추가',
                              style: _articleText(
                                context,
                                size: 10.5,
                                color: _kraftInk.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
      ),
    );
  }
}

/// 하나의 편지 안에서 세로로 읽는 문단.
class _LetterColumn extends StatelessWidget {
  final String title;
  final Widget child;
  const _LetterColumn({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: _kraftInk,
          ),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );
}

/// 타임테이블 메모(공연 상세 조회). 미등록/조회 전이면 안내.
class _RealTimetableNote extends StatefulWidget {
  final String? concertId;
  final Color ink;
  final Future<timetable_model.TimeTableResponse>? initialLoad;
  const _RealTimetableNote({
    required this.concertId,
    this.ink = _kraftInk,
    this.initialLoad,
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
      final res = await (widget.initialLoad ?? _service.getTimetable(id));
      if (!mounted) return;
      setState(() {
        _rows = res.contents
            .map(
              (e) => TimetableEntry(
                time: e.time ?? '',
                label: e.stage != null ? '${e.stage} · ${e.event}' : e.event,
              ),
            )
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
                      style: _articleText(
                        context,
                        size: 11.5,
                        weight: FontWeight.w900,
                        color: ink,
                      ),
                    ),
                    TextSpan(
                      text: _keepWords(r.label),
                      style: _articleText(context, size: 12, color: ink),
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
        style: _articleText(
          context,
          size: 12,
          weight: FontWeight.w700,
          color: ink.withValues(alpha: 0.55),
        ),
      );
    }
    return body;
  }
}
