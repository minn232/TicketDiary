import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/setlist.dart';
import '../models/ticket_info.dart';
import '../models/timetable.dart' as timetable_model;
import '../services/api_client.dart';
import '../services/concert_detail_service.dart';
import '../services/music_service_links.dart';
import '../services/ticket_service.dart';
import '../services/upload_service.dart';
import 'responsive_text.dart';
import 'concert_after_palette.dart';
import 'concert_after_editable_section.dart';
import 'scrapbook_page_background.dart';
import 'hanji_texture.dart';
import 'concert_after_text_canvas.dart';
import 'app_network_image.dart';
import 'setlist_editor_sheet.dart';
import 'setlist_music_service_control.dart';

/// 게스트 로그인 상태에서 로컬에 저장된 사진은 절대 파일 경로 문자열이라
/// `http(s)`로 시작하지 않습니다 — 이 차이로 [Image.network]/[Image.file] 중
/// 무엇을 쓸지 결정합니다.
bool _isNetworkUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

ImageProvider _concertAfterImageProvider(String imageKey) {
  return _isNetworkUrl(imageKey)
      ? CachedNetworkImageProvider(imageKey)
      : FileImage(File(imageKey)) as ImageProvider;
}

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

final Set<VoidCallback> _concertAfterFloatingControlClosers = {};

void hideConcertAfterFloatingControls() {
  for (final close in List<VoidCallback>.from(
    _concertAfterFloatingControlClosers,
  )) {
    close();
  }
}

/// 한 장의 공연 후 기록 페이지. 앞면에 포스터·사진과 자유 텍스트, 뒷면에 공연 상세를 배치합니다.
/// 텍스트는 빈 공간을 더블탭해 추가하고, 메모지와 겹치지 않게 자동 배치됩니다.
class ConcertAfterPageContents extends StatefulWidget {
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final Animation<double>? postItOpacity;
  final bool showCloseHint;
  final GlobalKey? pageBoundaryKey;

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
    this.pageBoundaryKey,
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
  int? _uploadingPhotoIndex;
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
  Future<void> _addPhoto(int index, double slotAspectRatio) async {
    if (!_ensureEditable() || _uploadingPhotoIndex != null) return;
    if (index < 0) return;

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

    setState(() => _uploadingPhotoIndex = index);
    try {
      final url = await _uploadService.uploadConcertPhoto(XFile(cropped.path));
      final List<String> nextUrls = [
        ...(_ticketInfo?.concertPhotoUrls ?? const <String>[]),
      ];
      while (nextUrls.length <= index) {
        nextUrls.add('');
      }
      nextUrls[index] = url;
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
      if (mounted) setState(() => _uploadingPhotoIndex = null);
    }
  }

  // [백엔드 수정]

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
      uploadingPhotoIndex: _uploadingPhotoIndex,
      onAddPhoto: _uploadingPhotoIndex == null ? _addPhoto : null,
      setlistTicketId: _ticketId,
      concertId: _ticketInfo?.concertId,
      initialTimetableLoad: _preloadedTimetable,
      initialSetlistLoad: _preloadedSetlist,
      pageBoundaryKey: widget.pageBoundaryKey,
    );

    return canvas;
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
  final SetlistServiceSelection selection;
  final ValueChanged<Future<void> Function(BuildContext context)>?
  onEditorReady;

  const _RealSetlistContent({
    required this.ticketId,
    this.ink = _kraftInk,
    this.initialLoad,
    required this.selection,
    this.onEditorReady,
  });

  @override
  State<_RealSetlistContent> createState() => _RealSetlistContentState();
}

class _RealSetlistContentState extends State<_RealSetlistContent> {
  static final Map<String, ({List<SongEntry> songs, List<String> artists})>
  _cache = {};

  final ConcertDetailService _service = ConcertDetailService();
  List<SongEntry>? _songs;
  List<String> _artistNames = const [];

  @override
  void initState() {
    super.initState();
    widget.onEditorReady?.call(_openEditor);
    final ticketId = widget.ticketId;
    final cached = ticketId == null ? null : _cache[ticketId];
    if (cached != null) {
      _songs = cached.songs;
      _artistNames = cached.artists;
      return;
    }
    _load();
  }

  @override
  void didUpdateWidget(covariant _RealSetlistContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onEditorReady != widget.onEditorReady ||
        oldWidget.ticketId != widget.ticketId) {
      widget.onEditorReady?.call(_openEditor);
    }
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
        _cache[ticketId] = (songs: res.songs, artists: res.artistNames);
      });
      if (res.songs.isEmpty) {
        _pollForUpdate(ticketId);
      }
    } on ApiException catch (_) {
      // 조회 자체가 실패하면(네트워크 오류 등) 조용히 안내 문구를 유지합니다.
    } catch (_) {}
  }

  // [백엔드 수정]
  // 서버가 이 화면 조회 시점에 실제 셋리스트가 비어있으면 백그라운드로 한 번 더
  // 채우기를 시도하는데(check_real_setlist_on_view), 응답은 그 결과를 기다리지 않고
  // 즉시 오므로 처음엔 항상 비어있음. 채워지면 화면을 나갔다 들어와야만 보이던 걸,
  // 1초 간격으로 최대 10번(~10초)만 짧게 재확인해서 그 안에 채워지면 자동 반영.
  // 10초 넘어가도 안 채워지면 포기 - 그 이상은 실패했거나 너무 늦게 나타나 어색함.
  Future<void> _pollForUpdate(String ticketId) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      try {
        final res = await _service.getRealSetlist(ticketId);
        if (!mounted) return;
        if (res.songs.isNotEmpty) {
          setState(() {
            _songs = res.songs;
            _artistNames = res.artistNames;
            _cache[ticketId] = (songs: res.songs, artists: res.artistNames);
          });
          return;
        }
      } on ApiException catch (_) {
      } catch (_) {}
    }
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

  // [백엔드 수정]
  // 셋리스트 유저 수정 진입점 신규. 저장 성공 시 서버 응답(res.songs/
  // artistNames)을 그대로 반영 - 태그/그룹핑까지 서버 응답 기준으로 다시
  // 계산되도록 로컬에서 임의로 합치지 않음.
  Future<void> _openEditor(BuildContext context) async {
    final ticketId = widget.ticketId;
    if (ticketId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('등록된 티켓에서만 실제 셋리스트를 수정할 수 있어요.')),
      );
      return;
    }
    await SetlistEditorSheet.show(
      context,
      initialSongs: _songs ?? const [],
      artistNames: _artistNames,
      onSave: (songs) async {
        final res = await _service.editRealSetlist(ticketId, songs);
        if (!mounted) return;
        setState(() {
          _songs = res.songs;
          _artistNames = res.artistNames;
          _cache[ticketId] = (songs: res.songs, artists: res.artistNames);
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [_buildBody(context)],
    );
  }

  Widget _buildBody(BuildContext context) {
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

    // 아티스트가 1명 이하(단독 공연)면 기존처럼 번호 목록 - song.artist 태그 유무와
    // 무관하게 songs를 그대로 씀. 예전엔 untaggedSongs가 비어있어야만 이 분기를
    // 탔는데, 특정 setlist.fm ID로 저장된 단독 공연(태그 자체를 안 붙임)은 아티스트가
    // 1명뿐이어도 전부 "아티스트 미상" 그룹으로 빠지는 문제가 있었음.
    if (allArtists.length <= 1) {
      if (songs.isEmpty) return _buildEmptyState();
      // 단독 공연은 song.artist가 비어있는 옛날 데이터가 많아서, 콘서트에
      // 등록된 아티스트(정확히 1명)를 검색용 폴백으로 씀.
      final fallbackArtist = allArtists.length == 1 ? allArtists.first : null;
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _buildRealSongRows(
            context,
            songs,
            widget.ink,
            selection: widget.selection,
            fallbackArtist: fallbackArtist,
          ),
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
      child: _RealSetlistGroupedByArtist(
        groups: groupList,
        ink: widget.ink,
        selection: widget.selection,
      ),
    );
  }
}

// [백엔드 수정]
// 곡마다 번호 매긴 Row + 앙코르 시작 지점 구분선을 만드는 헬퍼.
// 단독 공연 목록/아코디언 펼친 목록 둘 다 재사용
List<Widget> _buildRealSongRows(
  BuildContext context,
  List<SongEntry> songs,
  Color ink, {
  required ValueListenable<MusicService> selection,
  String? fallbackArtist,
}) {
  return [
    for (var i = 0; i < songs.length; i++) ...[
      if (songs[i].encore && (i == 0 || !songs[i - 1].encore))
        _EncoreDivider(ink: ink),
      Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => openSetlistSongSearch(
            selection,
            artist: songs[i].artist,
            fallbackArtist: fallbackArtist,
            songName: songs[i].name,
          ),
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
  final ValueListenable<MusicService> selection;

  const _RealSetlistGroupedByArtist({
    required this.groups,
    this.ink = _kraftInk,
    required this.selection,
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
              selection: widget.selection,
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
  final ValueListenable<MusicService> selection;

  const _RealSetlistArtistSection({
    required this.artistName,
    required this.songs,
    required this.expanded,
    required this.onTap,
    this.ink = _kraftInk,
    required this.selection,
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
                    children: _buildRealSongRows(
                      context,
                      songs,
                      ink,
                      selection: selection,
                    ),
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
// 잠금모드에서 페이지를 꾹 누르면 편집모드로 들어가고, 편집모드에서 각 메모지를
// 드래그(이동)·두 손가락(확대축소+회전)할 수 있습니다. 공연 후기는 더블탭하면
// 타이핑할 수 있습니다. 배치/크기/회전은
// 서버에 저장하지 않고 세션 동안만 [_scrapStore]/[_scrapZStore]에 담아둡니다.
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
  bool deleted = false;

  /// 드래그/확대 시작 시점에 측정해두는 메모지의 실제(배율 1) 크기.
  /// 경계 클램프 계산에 씁니다([_clampToCanvas] 참고).
  Size measuredSize = Size.zero;

  Map<String, Object> toJson() => {
    'dx': offset.dx,
    'dy': offset.dy,
    'scale': scale,
    'rotation': rotation,
    'placed': placed,
    'deleted': deleted,
  };

  void applyJson(Map<String, dynamic> json) {
    offset = Offset(
      ((json['dx'] as num?)?.toDouble() ?? 0),
      ((json['dy'] as num?)?.toDouble() ?? 0),
    );
    scale = ((json['scale'] as num?)?.toDouble() ?? 1).clamp(.4, 3.2);
    rotation = (json['rotation'] as num?)?.toDouble() ?? 0;
    placed = json['placed'] as bool? ?? false;
    deleted = json['deleted'] as bool? ?? false;
  }
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

const List<String> _defaultScrapZOrder = ['poster'];

String _photoMemoKey(int index) => 'photo_$index';
bool _isPhotoMemoKey(String key) => RegExp(r'^photo_\d+$').hasMatch(key);
int? _photoIndexFromKey(String key) {
  if (!_isPhotoMemoKey(key)) return null;
  return int.tryParse(key.substring('photo_'.length));
}

/// ticketId(또는 로컬 키)별 메모 배치/앞뒤 순서. 세션 동안만 유지(앱 재시작 시 초기화).
final Map<String, Map<String, _MemoTransform>> _scrapStore = {};
final Map<String, List<String>> _scrapZStore = {};
final Map<String, Map<int, double>> _scrapPhotoRatioStore = {};

class _ScrapbookCanvas extends StatefulWidget {
  final String layoutKey;
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final String? reviewText;
  final Future<void> Function(String) onReviewChanged;
  final List<String> photoUrls;
  final int? uploadingPhotoIndex;
  final Future<void> Function(int, double)? onAddPhoto;
  final String? setlistTicketId;
  final String? concertId;
  final Future<timetable_model.TimeTableResponse>? initialTimetableLoad;
  final Future<RealSetlistResponse>? initialSetlistLoad;
  final GlobalKey? pageBoundaryKey;

  const _ScrapbookCanvas({
    required this.layoutKey,
    required this.concertTitle,
    required this.ticketInfo,
    required this.reviewText,
    required this.onReviewChanged,
    required this.photoUrls,
    required this.uploadingPhotoIndex,
    required this.onAddPhoto,
    required this.setlistTicketId,
    required this.concertId,
    required this.initialTimetableLoad,
    required this.initialSetlistLoad,
    this.pageBoundaryKey,
  });

  @override
  State<_ScrapbookCanvas> createState() => _ScrapbookCanvasState();
}

class _ScrapbookCanvasState extends State<_ScrapbookCanvas>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  bool _showBack = false;
  double _flipDirection = 1;
  double _swipeDistance = 0;

  bool get _canFlip =>
      !_flip.isAnimating &&
      _activeMemoKey == null &&
      !(_textCanvasKey.currentState?.hasActiveText ?? false);

  void _finishSwipe(DragEndDetails details) {
    if (!_canFlip) return;
    final velocity = details.primaryVelocity ?? 0;
    if (_swipeDistance.abs() < 48 && velocity.abs() < 500) return;
    _cancelPageLongPress();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _flipDirection =
          (_swipeDistance.abs() >= 48 ? _swipeDistance : velocity) < 0 ? 1 : -1;
      _showBack = !_showBack;
    });
    _removeAddPhotoOverlay();
    _flip.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() {});
      _syncAddPhotoOverlay();
    });
  }

  Widget _flippablePage(Widget front) {
    final flipGestureEnabled = _canFlip;
    return Listener(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: flipGestureEnabled
            ? (_) {
                _swipeDistance = 0;
              }
            : null,
        onHorizontalDragUpdate: flipGestureEnabled
            ? (details) {
                _swipeDistance += details.delta.dx;
                _cancelPageLongPress();
              }
            : null,
        onHorizontalDragEnd: flipGestureEnabled ? _finishSwipe : null,
        onLongPress: _showBack
            ? () {
                if (!_flip.isAnimating) _toggleMode();
              }
            : null,
        child: AnimatedBuilder(
          animation: _flip,
          builder: (context, _) {
            final progress = Curves.easeInOutCubic.transform(_flip.value);
            final secondHalf = progress >= .5;
            final back = _flip.isAnimating
                ? (secondHalf ? _showBack : !_showBack)
                : _showBack;
            final angle = _flip.isAnimating
                ? _flipDirection *
                      math.pi *
                      (secondHalf ? progress - 1 : progress)
                : 0.0;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, .001)
                ..rotateY(angle),
              child: Container(
                foregroundDecoration: _edit
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: const Color(0xFFE53935),
                          width: context.rs(2.2),
                        ),
                      )
                    : null,
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F1E1),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.black.withValues(alpha: .10),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .22),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: IgnorePointer(
                    ignoring: _flip.isAnimating,
                    child: IndexedStack(
                      index: back ? 1 : 0,
                      sizing: StackFit.expand,
                      children: [
                        front,
                        PosterMoodScope(
                          mood: _posterMood,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              const ScrapbookPageBackground(),
                              _backPage(),
                              const ScrapbookPaperTextureOverlay(),
                              _modeBadge(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _modeBadge() => Positioned(
    bottom: context.rs(8),
    left: 0,
    right: 0,
    child: IgnorePointer(
      child: Center(child: _ModeBadge(edit: _edit)),
    ),
  );

  Widget _backPage() {
    final sections = _backContents();
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 16, 8, context.rs(48)),
      child: Column(
        children: [
          Text(
            widget.concertTitle,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _handTitle(context),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  Expanded(
                    child: SingleChildScrollView(
                      key: PageStorageKey('after_back_section_$i'),
                      child: sections[i],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color? _posterAccent;
  PosterMood? _posterMood;
  // 편지 안 "실제 셋 리스트" 섹션에서만 쓰는 선택값(설정탭 기본값에서 시작).
  // [SetlistServiceSelection] 문서 참고.
  final SetlistServiceSelection _setlistServiceSelection =
      SetlistServiceSelection();

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
    _concertAfterFloatingControlClosers.add(_floatingControlCloser);
    unawaited(_loadSavedLayout());
  }

  @override
  void didUpdateWidget(covariant _ScrapbookCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticketInfo?.posterImageUrl !=
        widget.ticketInfo?.posterImageUrl) {
      _loadEnvelopeAccent();
    }
    if (oldWidget.layoutKey != widget.layoutKey) {
      _layoutLoaded = false;
      unawaited(_loadSavedLayout());
    }
  }

  void _loadEnvelopeAccent() {
    _posterMood = null;
    final key = widget.ticketInfo?.posterImageUrl;
    final cachedMood = key == null ? null : _posterMoodValueCache[key];
    _posterMood = cachedMood;
    _posterAccent = cachedMood?.accent ?? _fallbackPosterAccentColor(key);
    if (key == null || key.isEmpty || cachedMood != null) return;

    unawaited(
      _extractPosterMood(key)
          .then((mood) {
            if (!mounted || widget.ticketInfo?.posterImageUrl != key) return;
            setState(() {
              _posterMood = mood;
              _posterAccent = mood.accent;
            });
          })
          .catchError((_) {}),
    );
  }

  final _textCanvasKey = GlobalKey<ConcertAfterTextCanvasState>();
  SharedPreferences? _prefs;
  bool _layoutLoaded = false;
  Future<void> _layoutWrite = Future.value();
  bool _edit = false;
  String? _activeMemoKey;
  Timer? _pageLongPressTimer;
  Offset? _pageLongPressDownPosition;
  late final Map<String, _MemoTransform> _t = _scrapStore.putIfAbsent(
    widget.layoutKey,
    () => {},
  );

  /// 그리는 순서(마지막이 맨 앞). 만진 메모를 앞으로 올립니다.
  /// layoutKey별로 같은 List 인스턴스를 보관해, 페이지를 닫았다 다시 열어도
  /// 편집모드에서 정한 위젯 앞뒤 순서가 유지되게 합니다.
  late final List<String> _z = _scrapZStore.putIfAbsent(
    widget.layoutKey,
    () => List<String>.from(_defaultScrapZOrder),
  );
  late final Map<int, double> _photoAspectRatios = _scrapPhotoRatioStore
      .putIfAbsent(widget.layoutKey, () => {});

  // 제스처 시작 시점 스냅샷.
  double _startScale = 1;
  double _startRot = 0;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  final ValueNotifier<int> _idleMemoFrame = ValueNotifier<int>(0);
  final ValueNotifier<int> _memoFrame = ValueNotifier<int>(0);
  bool _activeMemoOverDeleteZone = false;
  OverlayEntry? _deleteOverlayEntry;
  OverlayEntry? _addPhotoOverlayEntry;
  Future<void> Function(BuildContext context)? _setlistEditorLauncher;
  late final VoidCallback _floatingControlCloser = _removeAddPhotoOverlay;

  // 새 공연 후 페이지가 처음 생성될 때 적용되는 고정 기본 프리셋입니다.
  // 한 번 저장된 기본 프리셋은 특정 공연 페이지를 다시 편집해도 갱신하지 않습니다.
  static const String _fixedDefaultPresetPrefsKey =
      'concert_after_layout_fixed_default_preset_v1';

  String get _layoutPrefsKey => 'concert_after_layout_v3_${widget.layoutKey}';
  String get _legacyLayoutPrefsKey =>
      'concert_after_layout_v2_${widget.layoutKey}';
  Future<void> _loadSavedLayout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      final currentRaw = prefs.getString(_layoutPrefsKey);
      final legacyRaw = prefs.getString(_legacyLayoutPrefsKey);
      var fixedPresetRaw = prefs.getString(_fixedDefaultPresetPrefsKey);

      final raw = currentRaw ?? fixedPresetRaw ?? legacyRaw;
      if (raw == null || raw.isEmpty) {
        if (mounted) setState(() => _layoutLoaded = true);
        return;
      }
      _applySavedLayoutRaw(raw);
      if (currentRaw == null) {
        unawaited(prefs.setString(_layoutPrefsKey, raw));
      }
      if (mounted) setState(() => _layoutLoaded = true);
    } catch (_) {
      if (mounted) setState(() => _layoutLoaded = true);
    }
  }

  void _applySavedLayoutRaw(String raw) {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final memos = decoded['memos'] as Map<String, dynamic>? ?? const {};
    for (final entry in memos.entries) {
      final value = entry.value;
      if (value is Map) {
        _tf(entry.key).applyJson(value.cast<String, dynamic>());
      }
    }
    final order = (decoded['zOrder'] as List<dynamic>?)
        ?.whereType<String>()
        .toList();
    if (order != null && order.isNotEmpty) {
      _z
        ..clear()
        ..addAll(order);
      _normalizeZOrder();
    }
    final ratios = decoded['photoAspectRatios'] as Map<String, dynamic>?;
    if (ratios != null) {
      _photoAspectRatios
        ..clear()
        ..addEntries(
          ratios.entries
              .map(
                (entry) => MapEntry(
                  int.tryParse(entry.key),
                  (entry.value as num?)?.toDouble(),
                ),
              )
              .where((entry) => entry.key != null && entry.value != null)
              .map((entry) => MapEntry(entry.key!, entry.value!)),
        );
    }
  }

  void _persistLayout() {
    if (!_layoutLoaded) return;
    final payload = jsonEncode({
      'memos': {
        for (final entry in _t.entries) entry.key: entry.value.toJson(),
      },
      'zOrder': _z,
      'photoAspectRatios': {
        for (final entry in _photoAspectRatios.entries)
          entry.key.toString(): entry.value,
      },
    });
    _layoutWrite = _layoutWrite
        .then((_) async {
          final prefs = _prefs ?? await SharedPreferences.getInstance();
          _prefs = prefs;
          await prefs.setString(_layoutPrefsKey, payload);
        })
        .catchError((_) {});
  }

  _MemoTransform _tf(String k) => _t.putIfAbsent(k, () => _MemoTransform());

  /// 메모지별 GlobalKey(경계 클램프를 위한 실제 크기 측정용). 세션 배치와
  /// 달리 이 상태(State) 자신의 생애주기 동안만 유효합니다.
  final Map<String, GlobalKey> _memoKeys = {};
  GlobalKey _keyFor(String k) => _memoKeys.putIfAbsent(k, () => GlobalKey());

  @override
  void dispose() {
    _flip.dispose();
    _memoFrame.dispose();
    _idleMemoFrame.dispose();
    _removeDeleteOverlay();
    _removeAddPhotoOverlay();
    _concertAfterFloatingControlClosers.remove(_floatingControlCloser);
    _cancelPageLongPress();
    _setlistServiceSelection.dispose();
    super.dispose();
  }

  void _startPageLongPress(Offset position) {
    _cancelPageLongPress();
    if (_edit || _showBack || _flip.isAnimating) return;
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

  void _handleCanvasPointerDown(PointerDownEvent event) {
    if (_activeMemoKey != null) {
      final activeBounds = _activeMemoBounds();
      if (activeBounds != null && !activeBounds.contains(event.localPosition)) {
        _deselectActiveMemo();
        return;
      }
    }
    _startPageLongPress(event.position);
  }

  void _cancelPageLongPress() {
    _pageLongPressTimer?.cancel();
    _pageLongPressTimer = null;
    _pageLongPressDownPosition = null;
  }

  void _toggleMode() {
    setState(() {
      _edit = !_edit;
      if (!_edit) {
        _activeMemoKey = null;
        _activeMemoOverDeleteZone = false;
      }
      FocusManager.instance.primaryFocus?.unfocus();
    });
    _syncDeleteOverlay();
    _syncAddPhotoOverlay();
  }

  void _lockModeFromBlankSpace() {
    if (!_edit || _activeMemoKey != null) return;
    setState(() {
      _edit = false;
      _activeMemoOverDeleteZone = false;
      FocusManager.instance.primaryFocus?.unfocus();
    });
    _syncDeleteOverlay();
    _syncAddPhotoOverlay();
  }

  void _toggleMemoEditing(String key) {
    if (!_edit) return;
    if (_activeMemoKey != key) {
      _measureMemoForGesture(key, _tf(key));
    }
    setState(() {
      _activeMemoKey = _activeMemoKey == key ? null : key;
      _activeMemoOverDeleteZone = false;
      if (_activeMemoKey != null) _bringFront(key, updateState: false);
      FocusManager.instance.primaryFocus?.unfocus();
    });
    _syncDeleteOverlay();
  }

  void _deselectActiveMemo() {
    if (_activeMemoKey == null) return;
    setState(() {
      _activeMemoKey = null;
      _activeMemoOverDeleteZone = false;
    });
    _syncDeleteOverlay();
  }

  void _normalizeZOrder() {
    var changed = false;
    final validKeys = <String>{
      ..._defaultScrapZOrder,
      for (var i = 0; i < widget.photoUrls.length; i++) _photoMemoKey(i),
    };
    for (final key in validKeys) {
      if (!_z.contains(key)) {
        _z.add(key);
        changed = true;
      }
    }
    final stale = _z.where((key) => !validKeys.contains(key)).toList();
    if (stale.isNotEmpty) {
      _z.removeWhere(stale.contains);
      changed = true;
    }
    if (changed) _scrapZStore[widget.layoutKey] = _z;
  }

  void _bringFront(String k, {bool updateState = true}) {
    _normalizeZOrder();
    if (_z.isNotEmpty && _z.last == k) return;
    void apply() {
      _z.remove(k);
      _z.add(k);
      _scrapZStore[widget.layoutKey] = _z;
      _persistLayout();
    }

    if (updateState) {
      setState(apply);
    } else {
      apply();
    }
  }

  bool _isMemoDeleted(String key) => _t[key]?.deleted ?? false;

  Rect _screenDeleteZoneRect() {
    final media = MediaQuery.of(context);
    final bottomPadding = media.padding.bottom;
    final height = context.rs(56);
    return Rect.fromLTWH(
      context.rs(18),
      media.size.height - bottomPadding - height - context.rs(8),
      media.size.width - context.rs(36),
      height,
    );
  }

  void _deleteActiveMemo() {
    final key = _activeMemoKey;
    if (key == null) return;
    final t = _tf(key);
    setState(() {
      t.deleted = true;
      _activeMemoKey = null;
      _activeMemoOverDeleteZone = false;
    });
    _persistLayout();
    _syncDeleteOverlay();
  }

  void _syncDeleteOverlay() {
    if (!_edit || _activeMemoKey == null) {
      _removeDeleteOverlay();
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    if (_deleteOverlayEntry == null) {
      _deleteOverlayEntry = OverlayEntry(
        builder: (context) => _ScreenDeleteDropZone(
          rect: _screenDeleteZoneRect(),
          active: _activeMemoOverDeleteZone,
        ),
      );
      overlay.insert(_deleteOverlayEntry!);
    } else {
      _deleteOverlayEntry!.markNeedsBuild();
    }
  }

  void _removeDeleteOverlay() {
    _deleteOverlayEntry?.remove();
    _deleteOverlayEntry = null;
  }

  void _syncAddPhotoOverlay() {
    if (!_edit || _showBack || _flip.isAnimating || widget.onAddPhoto == null) {
      _removeAddPhotoOverlay();
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    if (_addPhotoOverlayEntry == null) {
      _addPhotoOverlayEntry = OverlayEntry(
        builder: (context) {
          const buttonHeight = 38.0;
          final resolvedButtonHeight = context.rs(buttonHeight);
          final boundaryBox =
              widget.pageBoundaryKey?.currentContext?.findRenderObject()
                  as RenderBox?;
          final ownBox = this.context.findRenderObject() as RenderBox?;
          final pageBox = boundaryBox?.hasSize == true ? boundaryBox : ownBox;
          final pageSize = pageBox?.hasSize == true
              ? pageBox!.size
              : MediaQuery.of(context).size;
          final pageTop = pageBox?.hasSize == true
              ? pageBox!.localToGlobal(Offset.zero).dy
              : resolvedButtonHeight * 1.5;
          final top = pageTop - resolvedButtonHeight * 1.5;
          return Positioned(
            top: top,
            left: 0,
            right: 0,
            child: Center(
              child: SizedBox(
                width: pageSize.width * .5,
                child: _AddPhotoButton(
                  height: buttonHeight,
                  busy: widget.uploadingPhotoIndex != null,
                  onTap: _showAddPhotoMenu,
                ),
              ),
            ),
          );
        },
      );
      overlay.insert(_addPhotoOverlayEntry!);
    } else {
      _addPhotoOverlayEntry!.markNeedsBuild();
    }
  }

  void _removeAddPhotoOverlay() {
    _addPhotoOverlayEntry?.remove();
    _addPhotoOverlayEntry = null;
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
      if (t.deleted) return;
      if (!t.placed) {
        t.offset = Offset(dx, dy);
        t.rotation = rot;
        t.placed = true;
      }
    }

    def('poster', w * 0.05, titleSafeBottom + 12, 0);
    for (var i = 0; i < widget.photoUrls.length; i++) {
      final col = i % 3;
      final row = i ~/ 3;
      final dx = w * (.08 + col * .28);
      final dy = titleSafeBottom + context.rs(22) + row * h * .16;
      def(_photoMemoKey(i), dx, dy, 0);
    }
  }

  Widget _editableBackSection(
    int index,
    String title,
    Widget child, {
    bool editable = true,
    Future<void> Function(BuildContext context)? editOverride,
  }) {
    final key = 'after_back_text_v1_${widget.layoutKey}_$index';
    return ConcertAfterEditableSection(
      key: ValueKey(key),
      storageKey: key,
      editMode: _edit,
      editable: editable,
      title: title,
      loadOriginal: () => _originalBackText(index),
      editOverride: editOverride,
      child: child,
    );
  }

  List<MapEntry<String, String>> _backInfoFields() {
    final info = widget.ticketInfo;
    final extras = info?.extraFields ?? const <String, String>{};
    final values = <String, String>{
      '공연장': info?.venueName ?? '',
      '날짜': info?.formattedDate ?? '',
      '가격': info?.price ?? '',
      '좌석': info?.seat ?? '',
      '아티스트': extras['아티스트'] ?? extras['artist'] ?? '',
      '공연 유형': extras['공연 유형'] ?? extras['공연 타입'] ?? extras['유형'] ?? '',
    };
    return [
      for (final key in const ['공연장', '날짜', '가격', '좌석', '아티스트', '공연 유형'])
        MapEntry(key, values[key]?.isEmpty == true ? '-' : values[key] ?? '-'),
    ];
  }

  Future<String> _originalBackText(int index) async {
    if (index == 0) {
      return (widget.ticketInfo?.displayFields ?? <MapEntry<String, String>>[])
          .map((field) => '${field.key}\n${field.value}')
          .join('\n\n');
    }
    final service = ConcertDetailService();
    if (index == 1) {
      if (widget.concertId == null) return '';
      final response =
          await (widget.initialTimetableLoad ??
              service.getTimetable(widget.concertId!));
      return response.contents
          .map(
            (entry) => [entry.date, entry.time, entry.stage, entry.event]
                .whereType<String>()
                .where((value) => value.isNotEmpty)
                .join(' · '),
          )
          .join('\n');
    }
    if (widget.setlistTicketId == null) return '';
    // Use the latest result, including songs populated after the initial load.
    final response = await service.getRealSetlist(widget.setlistTicketId!);
    return response.songs
        .map(
          (song) => [
            if (song.encore) '[앙코르]',
            if (song.artist?.isNotEmpty == true) song.artist!,
            song.name,
          ].join(' · '),
        )
        .join('\n');
  }

  List<Widget> _backContents() {
    final timetableFuture = widget.initialTimetableLoad;
    final setlistFuture = widget.initialSetlistLoad;
    return [
      _LetterColumn(
        title: '공연 정보',
        child: _editableBackSection(
          0,
          '공연 정보',
          SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final field in _backInfoFields())
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
          editable: false,
        ),
      ),
      _LetterColumn(
        title: '타임테이블',
        child: _editableBackSection(
          1,
          '타임테이블',
          SingleChildScrollView(
            child: _RealTimetableNote(
              concertId: widget.concertId,
              ink: _kraftInk,
              initialLoad: timetableFuture,
            ),
          ),
          editable: false,
        ),
      ),
      _LetterColumn(
        title: '실제 셋 리스트',
        trailing: SetlistServiceIcon(selection: _setlistServiceSelection),
        child: _editableBackSection(
          2,
          '실제 셋 리스트',
          _RealSetlistContent(
            ticketId: widget.setlistTicketId,
            ink: _kraftInk,
            initialLoad: setlistFuture,
            selection: _setlistServiceSelection,
            onEditorReady: (launcher) {
              _setlistEditorLauncher = launcher;
            },
          ),
          editOverride: (context) async {
            final launcher = _setlistEditorLauncher;
            if (launcher != null) await launcher(context);
          },
        ),
      ),
    ];
  }

  static const double _widgetDefaultSizeBoost = 1.5;

  double _memoBaseWidth(String key, double width) {
    if (_isPhotoMemoKey(key)) {
      final ratio = _memoAspectRatio(key);
      final baseHeight = width * .266;
      return _widgetDefaultSizeBoost * baseHeight * ratio;
    }
    return _widgetDefaultSizeBoost *
        switch (key) {
          'poster' => width * .21,
          _ => width * .26,
        };
  }

  double _photoAspectRatio(int index) => _photoAspectRatios[index] ?? 1;

  double _memoAspectRatio(String key) => switch (key) {
    'poster' => 3 / 4,
    _ when _isPhotoMemoKey(key) => _photoAspectRatio(
      _photoIndexFromKey(key) ?? 0,
    ),
    _ => 1,
  };

  Size _memoFallbackSize(String key, double width) {
    final fallbackW = _memoBaseWidth(key, width);
    return Size(fallbackW, fallbackW / _memoAspectRatio(key));
  }

  Future<void> _showAddPhotoMenu() async {
    if (widget.onAddPhoto == null) return;
    final ratio = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _PhotoRatioSheet(),
    );
    if (ratio == null || !mounted) return;
    final index = widget.photoUrls.length;
    setState(() {
      _photoAspectRatios[index] = ratio;
      final key = _photoMemoKey(index);
      _tf(key).deleted = false;
      if (!_z.contains(key)) _z.add(key);
    });
    _persistLayout();
    await widget.onAddPhoto!(index, ratio);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncAddPhotoOverlay();
        });
        final w = c.maxWidth;
        final h = c.maxHeight;
        final titleSafeBottom = _titleSafeBottom(w);
        _normalizeZOrder();
        _placeDefaults(w, h, titleSafeBottom);
        _clampPlacedMemos(w, h, titleSafeBottom);

        final items = <String, Widget>{
          if (!_isMemoDeleted('poster'))
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
          for (var index = 0; index < widget.photoUrls.length; index++)
            if (!_isMemoDeleted(_photoMemoKey(index)))
              _photoMemoKey(index): _memo(
                _photoMemoKey(index),
                baseW: _memoBaseWidth(_photoMemoKey(index), w),
                canvasW: w,
                canvasH: h,
                titleSafeBottom: titleSafeBottom,
                child: _editableWidgetTone(
                  edit: _edit,
                  child: _PolaroidMemo(
                    aspectRatio: _photoAspectRatio(index),
                    url: widget.photoUrls[index],
                    edit: _edit,
                    uploading: widget.uploadingPhotoIndex == index,
                    onAdd: null,
                  ),
                ),
              ),
        };

        final backgroundOverlays = [
          _AfterDecorativeBoxes(
            seedKey:
                '${widget.layoutKey}_${widget.ticketInfo?.posterImageUrl ?? ''}',
            posterKey: widget.ticketInfo?.posterImageUrl,
            contentTop: titleSafeBottom,
            width: w,
            height: h,
          ),
        ];
        final memoWidgets = [
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
        ];
        return _flippablePage(
          ClipRect(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _handleCanvasPointerDown,
              onPointerMove: (event) =>
                  _maybeCancelPageLongPress(event.position),
              onPointerUp: (_) => _cancelPageLongPress(),
              onPointerCancel: (_) => _cancelPageLongPress(),
              child: Stack(
                children: [
                  PosterMoodScope(
                    mood: _posterMood,
                    child: ValueListenableBuilder<int>(
                      valueListenable: _memoFrame,
                      builder: (context, value, child) =>
                          ConcertAfterTextCanvas(
                            key: _textCanvasKey,
                            storageKey: widget.layoutKey,
                            initialReview: widget.reviewText ?? '',
                            width: w,
                            minHeight: h,
                            minContentTop: titleSafeBottom,
                            editMode: _edit && _activeMemoKey == null,
                            obstacles: const <Rect>[],
                            backgroundOverlays: backgroundOverlays,
                            onReviewChanged: widget.onReviewChanged,
                            onBlankLongPress: _lockModeFromBlankSpace,
                            memos: memoWidgets,
                          ),
                    ),
                  ),
                  ValueListenableBuilder<int>(
                    valueListenable: _memoFrame,
                    builder: (context, value, child) => _activeMemoDimOverlay(),
                  ),
                  _modeBadge(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Rect? _activeMemoBounds() {
    final key = _activeMemoKey;
    if (key == null) return null;
    final t = _t[key];
    if (t == null) return null;
    if (t.measuredSize == Size.zero) _measureMemoForGesture(key, t);
    final size = t.measuredSize == Size.zero ? null : t.measuredSize;
    if (size == null) return null;
    return MatrixUtils.transformRect(
      Matrix4.identity()
        ..translateByDouble(
          t.offset.dx + size.width / 2,
          t.offset.dy + size.height / 2,
          0,
          1,
        )
        ..rotateZ(t.rotation)
        ..scaleByDouble(t.scale, t.scale, 1, 1)
        ..translateByDouble(-size.width / 2, -size.height / 2, 0, 1),
      Offset.zero & size,
    );
  }

  Widget _activeMemoDimOverlay() {
    final activeBounds = _activeMemoBounds();
    if (!_edit || _activeMemoKey == null || activeBounds == null) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: CustomPaint(
        painter: _ActiveMemoDimPainter(activeBounds),
        size: Size.infinite,
      ),
    );
  }

  void _clampPlacedMemos(
    double canvasW,
    double canvasH,
    double titleSafeBottom,
  ) {
    for (final key in _z) {
      final t = _tf(key);
      if (t.deleted) continue;
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

  void _measureMemoForGesture(String key, _MemoTransform t) {
    final box = _keyFor(key).currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) t.measuredSize = box.size;
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
      final memoEditing = _activeMemoKey == key;
      gestured = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _toggleMemoEditing(key),
        onScaleStart: memoEditing
            ? (d) {
                _bringFront(key);
                _startScale = t.scale;
                _startRot = t.rotation;
                _startOffset = t.offset;
                _startFocal = d.focalPoint;
                // 드래그 시작 시점의 실제(배율 1) 렌더 크기를 측정해둡니다 —
                // 경계 클램프 계산에 필요합니다.
                _measureMemoForGesture(key, t);
              }
            : null,
        onScaleUpdate: memoEditing
            ? (d) {
                final dragDelta = d.focalPoint - _startFocal;
                final rawOffset = _startOffset + dragDelta;
                final rawScale = _startScale * d.scale;
                final rawRotation = _startRot + d.rotation;
                final newScale = _clampMemoScaleToCanvas(
                  rawScale,
                  rawRotation,
                  t.measuredSize,
                  canvasW,
                  canvasH,
                  minTop: titleSafeBottom,
                );
                t.scale = newScale;
                t.rotation = rawRotation;
                final clamped = _clampToCanvas(
                  rawOffset,
                  newScale,
                  rawRotation,
                  t.measuredSize,
                  canvasW,
                  canvasH + context.rs(96),
                  minTop: titleSafeBottom,
                );
                t.offset = Offset(clamped.dx, clamped.dy);
                final overDelete = _screenDeleteZoneRect().contains(
                  d.focalPoint,
                );
                if (_activeMemoOverDeleteZone != overDelete) {
                  _activeMemoOverDeleteZone = overDelete;
                  _deleteOverlayEntry?.markNeedsBuild();
                }
                _memoFrame.value++;
              }
            : null,
        onScaleEnd: memoEditing
            ? (_) {
                if (_activeMemoOverDeleteZone) {
                  _deleteActiveMemo();
                  return;
                }
                setState(() {
                  _activeMemoOverDeleteZone = false;
                });
                _deleteOverlayEntry?.markNeedsBuild();
                _persistLayout();
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          foregroundDecoration: memoEditing
              ? BoxDecoration(
                  border: Border.all(
                    color: const Color(0xFFE53935).withValues(alpha: .95),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: IgnorePointer(
            ignoring: _activeMemoKey != null && !memoEditing,
            child: content,
          ),
        ),
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
      child: ValueListenableBuilder<int>(
        valueListenable: _activeMemoKey == key ? _memoFrame : _idleMemoFrame,
        child: RepaintBoundary(child: gestured),
        builder: (context, value, stableChild) => Transform.translate(
          offset: t.offset,
          child: Transform.rotate(
            angle: t.rotation,
            child: Transform.scale(scale: t.scale, child: stableChild),
          ),
        ),
      ),
    );
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

String _posterMoodPrefsKey(String posterKey) =>
    'concert_after_poster_mood_${_stableSeed(posterKey)}';

Map<String, Object> _posterMoodToJson(PosterMood mood) => {
  'accent': mood.accent.toARGB32(),
  'saturation': mood.saturation,
  'brightness': mood.brightness,
  'contrast': mood.contrast,
  'detail': mood.detail,
};

PosterMood? _posterMoodFromJson(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  final accent = value['accent'];
  final saturation = value['saturation'];
  final brightness = value['brightness'];
  final contrast = value['contrast'];
  final detail = value['detail'];
  if (accent is! num ||
      saturation is! num ||
      brightness is! num ||
      contrast is! num ||
      detail is! num) {
    return null;
  }
  return PosterMood(
    Color(accent.toInt()),
    saturation.toDouble(),
    brightness.toDouble(),
    contrast.toDouble(),
    detail.toDouble(),
  );
}

Future<PosterMood?> _loadPosterMoodFromPrefs(String posterKey) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_posterMoodPrefsKey(posterKey));
    if (raw == null || raw.isEmpty) return null;
    return _posterMoodFromJson(jsonDecode(raw));
  } catch (_) {
    return null;
  }
}

Future<void> _savePosterMoodToPrefs(String posterKey, PosterMood mood) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _posterMoodPrefsKey(posterKey),
      jsonEncode(_posterMoodToJson(mood)),
    );
  } catch (_) {}
}

// 동일 포스터는 페이지/네모상자에서 한 번만 분석한다. 최근 12개만 보관한다.
final _posterMoodCache = <String, Future<PosterMood>>{};
final _posterMoodValueCache = <String, PosterMood>{};
Future<PosterMood> _extractPosterMood(String posterKey) {
  final value = _posterMoodValueCache[posterKey];
  if (value != null) return Future.value(value);
  final cached = _posterMoodCache[posterKey];
  if (cached != null) return cached;
  if (_posterMoodCache.length >= 12) {
    final oldest = _posterMoodCache.keys.first;
    _posterMoodCache.remove(oldest);
    _posterMoodValueCache.remove(oldest);
  }
  final pending = _loadOrAnalyzePosterMood(posterKey).then((mood) {
    _posterMoodValueCache[posterKey] = mood;
    return mood;
  });
  _posterMoodCache[posterKey] = pending;
  return pending;
}

Future<PosterMood> _loadOrAnalyzePosterMood(String posterKey) async {
  final saved = await _loadPosterMoodFromPrefs(posterKey);
  if (saved != null) return saved;
  final analyzed = await _analyzePosterMood(posterKey);
  unawaited(_savePosterMoodToPrefs(posterKey, analyzed));
  return analyzed;
}

Future<PosterMood> _analyzePosterMood(String posterKey) async {
  final provider = _concertAfterImageProvider(posterKey);
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
          ],
        ),
      ),
    );
  }

  Offset _decorativeBoxPosition(
    math.Random rnd, {
    required double boxW,
    required double boxH,
    required double edgeX,
    required double edgeY,
    required double usableW,
    required double usableH,
  }) {
    final minX = edgeX;
    final maxX = edgeX + math.max(0.0, usableW - boxW);
    final minY = edgeY;
    final maxY = edgeY + math.max(0.0, usableH - boxH);

    // 크라프트지의 중심이 페이지 중앙 50% x 50% 영역에 오지 않게 한다.
    // 중앙을 비워두면 큰 종이들이 페이지 가장자리로 자연스럽게 퍼져 보인다.
    final forbiddenLeft = widget.width * .25;
    final forbiddenRight = widget.width * .75;
    final forbiddenTop = widget.height * .25;
    final forbiddenBottom = widget.height * .75;

    bool centerAllowed(double dx, double dy) {
      final cx = dx + boxW / 2;
      final cy = dy + boxH / 2;
      return cx < forbiddenLeft ||
          cx > forbiddenRight ||
          cy < forbiddenTop ||
          cy > forbiddenBottom;
    }

    for (var attempt = 0; attempt < 24; attempt++) {
      final dx = minX + rnd.nextDouble() * math.max(0.0, maxX - minX);
      final dy = minY + rnd.nextDouble() * math.max(0.0, maxY - minY);
      if (centerAllowed(dx, dy)) return Offset(dx, dy);
    }

    var dx = minX + rnd.nextDouble() * math.max(0.0, maxX - minX);
    var dy = minY + rnd.nextDouble() * math.max(0.0, maxY - minY);
    final cx = dx + boxW / 2;
    final cy = dy + boxH / 2;
    if (!centerAllowed(dx, dy)) {
      final distances = <double, Offset>{
        (cx - forbiddenLeft).abs(): Offset(forbiddenLeft - boxW / 2, dy),
        (cx - forbiddenRight).abs(): Offset(forbiddenRight - boxW / 2, dy),
        (cy - forbiddenTop).abs(): Offset(dx, forbiddenTop - boxH / 2),
        (cy - forbiddenBottom).abs(): Offset(dx, forbiddenBottom - boxH / 2),
      };
      final nearest = distances.keys.reduce(math.min);
      final pushed = distances[nearest]!;
      dx = pushed.dx.clamp(minX, maxX).toDouble();
      dy = pushed.dy.clamp(minY, maxY).toDouble();
    }
    return Offset(dx, dy);
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
    final position = _decorativeBoxPosition(
      rnd,
      boxW: boxW,
      boxH: boxH,
      edgeX: edgeX,
      edgeY: edgeY,
      usableW: usableW,
      usableH: usableH,
    );
    final dx = position.dx;
    final dy = position.dy;
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

class _ScreenDeleteDropZone extends StatelessWidget {
  final Rect rect;
  final bool active;

  const _ScreenDeleteDropZone({required this.rect, required this.active});

  @override
  Widget build(BuildContext context) {
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: Material(
          type: MaterialType.transparency,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:
                  (active ? const Color(0xFFE53935) : const Color(0xFF3E3024))
                      .withValues(alpha: active ? .9 : .68),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withValues(alpha: active ? .9 : .5),
                width: active ? 2 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .26),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.delete_outline, color: Colors.white, size: 20),
                const SizedBox(width: 7),
                Text(
                  active ? '놓으면 삭제' : '아래로 끌어 삭제',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    decoration: TextDecoration.none,
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

class _ActiveMemoDimPainter extends CustomPainter {
  final Rect activeBounds;

  const _ActiveMemoDimPainter(this.activeBounds);

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    final highlight = RRect.fromRectAndRadius(
      activeBounds.inflate(8),
      const Radius.circular(12),
    );
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(full)
      ..addRRect(highlight);
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: .22));
  }

  @override
  bool shouldRepaint(covariant _ActiveMemoDimPainter oldDelegate) =>
      activeBounds != oldDelegate.activeBounds;
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

class _AddPhotoButton extends StatelessWidget {
  final double height;
  final bool busy;
  final VoidCallback onTap;

  const _AddPhotoButton({
    this.height = 38,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          height: context.rs(height),
          padding: EdgeInsets.symmetric(horizontal: context.rs(14)),
          decoration: BoxDecoration(
            color: const Color(0xFFF6E9CC).withValues(alpha: .94),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: _kraftInk.withValues(alpha: .22)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .16),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(
            child: busy
                ? SizedBox(
                    width: context.rs(16),
                    height: context.rs(16),
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.add_photo_alternate_outlined,
                        size: context.rs(18),
                        color: _kraftInk,
                      ),
                      SizedBox(width: context.rs(6)),
                      Text(
                        '사진 추가',
                        style: TextStyle(
                          color: _kraftInk,
                          fontSize: context.sp(12),
                          fontWeight: FontWeight.w800,
                          decoration: TextDecoration.none,
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

class _PhotoRatioSheet extends StatelessWidget {
  _PhotoRatioSheet();

  final List<({String label, double ratio, IconData icon})> _ratios = const [
    (label: '1:1', ratio: 1, icon: Icons.crop_square_rounded),
    (label: '4:3', ratio: 4 / 3, icon: Icons.crop_landscape_rounded),
    (label: '3:4', ratio: 3 / 4, icon: Icons.crop_portrait_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          context.rs(18),
          0,
          context.rs(18),
          context.rs(14),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFF4F1E1),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _kraftInk.withValues(alpha: .12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .22),
                blurRadius: 18,
                offset: const Offset(0, 9),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(context.rs(14)),
            child: Row(
              children: [
                for (final item in _ratios)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: context.rs(4)),
                      child: InkWell(
                        onTap: () => Navigator.of(context).pop(item.ratio),
                        borderRadius: BorderRadius.circular(12),
                        child: Ink(
                          padding: EdgeInsets.symmetric(
                            vertical: context.rs(12),
                          ),
                          decoration: BoxDecoration(
                            color: concertAfterTone(
                              hue: 39,
                              saturation: .16,
                              value: .88,
                            ),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _kraftInk.withValues(alpha: .12),
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                item.icon,
                                color: _kraftInk.withValues(alpha: .8),
                                size: context.rs(24),
                              ),
                              SizedBox(height: context.rs(5)),
                              Text(
                                item.label,
                                style: TextStyle(
                                  color: _kraftInk,
                                  fontSize: context.sp(12),
                                  fontWeight: FontWeight.w800,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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
      child: RepaintBoundary(
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
              isComplex: true,
              willChange: false,
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

/// 바랜 종이 인쇄: 무거운 픽셀 단위 색상 필터 대신 옅은 종이색 오버레이를
/// 얹어 포스터와 사진을 살짝 누렇게 보이게 한다.
class _PaperImageEffect extends StatelessWidget {
  final Widget child;
  const _PaperImageEffect({required this.child});

  Color _paperTint(BuildContext context) {
    final mood = PosterMoodScope.of(context);
    if (mood == null) return const Color(0x2FE7D2A3);
    return Color.alphaBlend(
      mood.materialColor.withValues(alpha: .10),
      const Color(0x29E7D2A3),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textureOpacity =
        PosterMoodScope.of(context)?.textureOpacity ?? kHanjiTextureOpacity;
    return RepaintBoundary(
      child: ClipRect(
        child: HanjiTexture(
          opacity: textureOpacity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              IgnorePointer(child: ColoredBox(color: _paperTint(context))),
            ],
          ),
        ),
      ),
    );
  }
}

/// 사진 슬롯. 각 슬롯의 표시 비율과 업로드 크롭 비율을 함께 맞춘다.
class _PolaroidMemo extends StatelessWidget {
  final double aspectRatio;
  final String? url;
  final bool edit;
  final bool uploading;
  final Future<void> Function(double)? onAdd;

  const _PolaroidMemo({
    required this.aspectRatio,
    required this.url,
    required this.edit,
    required this.uploading,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final has = url != null && url!.isNotEmpty;
    return _photo(context, has);
  }

  Widget _photo(BuildContext context, bool has) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        Container(
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
                ? _PaperImageEffect(
                    child: _isNetworkUrl(url!)
                        ? AppNetworkImage(
                            url!,
                            fit: BoxFit.cover,
                            errorBuilder: (c) =>
                                const ColoredBox(color: Color(0x22000000)),
                          )
                        : Image.file(File(url!), fit: BoxFit.cover),
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
                          : Icon(
                              Icons.add_a_photo_outlined,
                              size: context.rs(22),
                              color: _kraftInk.withValues(alpha: 0.6),
                            ),
                    ),
                  ),
          ),
        ),
        Positioned(
          top: -context.rs(8),
          child: Transform.rotate(
            angle: -0.035,
            child: HanjiTexture(
              opacity:
                  PosterMoodScope.of(context)?.textureOpacity ??
                  kHanjiTextureOpacity,
              child: Container(
                width: context.rs(58),
                height: context.rs(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAD8AF).withValues(alpha: .74),
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .18),
                    width: .7,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 하나의 편지 안에서 세로로 읽는 문단.
class _LetterColumn extends StatelessWidget {
  final String title;
  final Widget child;
  // "실제 셋 리스트" 칸에서만 쓰는 서비스 아이콘(다른 칸은 안 씀).
  final Widget? trailing;
  const _LetterColumn({
    required this.title,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
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
        if (trailing != null) ...[const SizedBox(height: 6), trailing!],
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
  static final Map<String, List<TimetableEntry>> _cache = {};

  final ConcertDetailService _service = ConcertDetailService();
  List<TimetableEntry> _rows = const [];
  String _status = 'loading'; // loading | empty | error | loaded

  @override
  void initState() {
    super.initState();
    final id = widget.concertId;
    final cached = id == null ? null : _cache[id];
    if (cached != null) {
      _rows = cached;
      _status = cached.isEmpty ? 'empty' : 'loaded';
      return;
    }
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
        _cache[id] = _rows;
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
