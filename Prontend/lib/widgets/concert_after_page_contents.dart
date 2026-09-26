import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/page_layout.dart';
import '../main/orientation_policy.dart';
import '../models/setlist.dart';
import '../models/ticket_info.dart';
import '../models/timetable.dart' as timetable_model;
import '../services/api_client.dart';
import '../services/concert_detail_service.dart';
import '../services/layout_config_service.dart';
import '../services/music_service_links.dart';
import '../services/scrapbook_auto_layout.dart';
import '../services/ticket_service.dart';
import '../services/upload_service.dart';
import 'responsive_text.dart';
import 'concert_after_palette.dart';
import 'concert_after_editable_section.dart';
import 'concert_after_share_sheet.dart';
import 'scrapbook_page_background.dart';
import 'hanji_texture.dart';
import 'concert_after_text_canvas.dart';
import 'concert_before_page_contents.dart';
import 'app_network_image.dart';
import 'artist_identity_sheet.dart';
import 'underlined_text.dart';
import 'setlist_editor_sheet.dart';
import 'setlist_empty_message.dart';
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

  // [백엔드 수정] 뒷면 "공연 전 신문" 썸네일용 호수/열기 콜백 신규.
  final int issueNumber;

  /// null이면 썸네일만 보이고 눌리지 않음.
  final Future<void> Function(Rect startRect, Widget collapsed)?
  onOpenBeforePage;

  const ConcertAfterPageContents({
    super.key,
    required this.concertTitle,
    this.ticketInfo,
    this.postItOpacity,
    this.showCloseHint = true,
    this.onTicketInfoChanged,
    this.pageBoundaryKey,
    this.issueNumber = 1,
    this.onOpenBeforePage,
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
  bool _uploadingPhotos = false;
  Timer? _layoutSaveTimer;
  PageLayout? _pendingLayout;
  int _photoIdSeq = 0;
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
  void dispose() {
    // 닫기 직전 편집분이 저장 대기 중이면 바로 보냄.
    if (_layoutSaveTimer?.isActive ?? false) {
      _layoutSaveTimer!.cancel();
      unawaited(_flushLayout());
    }
    super.dispose();
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

  /// 갤러리에서 여러 장을 골라 원본 비율 그대로(크롭 없음) 업로드.
  /// 일부만 성공해도 성공한 사진은 반환함.
  Future<List<_AfterPhoto>> _pickAndUploadPhotos() async {
    if (!_ensureEditable() || _uploadingPhotos) return const [];
    final picked = await _imagePicker.pickMultiImage(
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    if (picked.isEmpty || !mounted) return const [];

    setState(() => _uploadingPhotos = true);
    final added = <_AfterPhoto>[];
    try {
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        final size = await _decodeOrientedSize(bytes);
        // [백엔드 수정] 썸네일(thumbnail)은 JPEG 인코더 도입 후 같이 보낼 예정
        final (url, thumbUrl) = await _uploadService.uploadConcertPhotoBytes(
          bytes,
        );
        added.add(
          _AfterPhoto(
            id:
                'p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
                '${_photoIdSeq++}',
            url: url,
            thumbUrl: thumbUrl,
            width: size.width.round(),
            height: size.height.round(),
          ),
        );
      }
    } on ApiException catch (e) {
      _showSnack('사진 추가에 실패했어요: ${e.message}');
    } catch (_) {
      _showSnack('사진 추가 중 오류가 발생했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _uploadingPhotos = false);
    }
    return added;
  }

  /// 캔버스 배치가 바뀔 때마다 호출. 연속 변경은 모아서 0.6초 뒤 한 번만 서버에 저장.
  void _onLayoutChanged(PageLayout layout) {
    _ticketInfo = _ticketInfo?.copyWith(pageLayout: layout);
    _pendingLayout = layout;
    if (!mounted) {
      // 페이지가 닫히는 중 마지막 변경 (자유메모 캔버스 dispose 등) → 바로 저장.
      unawaited(_flushLayout());
      return;
    }
    _layoutSaveTimer?.cancel();
    _layoutSaveTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(_flushLayout());
    });
  }

  Future<void> _flushLayout() async {
    final layout = _pendingLayout;
    _pendingLayout = null;
    final ticketId = _ticketId;
    if (layout == null || ticketId == null) return;
    try {
      await _ticketService.updateTicket(ticketId, pageLayout: layout);
      if (_ticketInfo != null) widget.onTicketInfoChanged?.call(_ticketInfo!);
    } catch (_) {
      // 기기 캐시에는 남아 있어 다음 편집 때 다시 저장됨.
    }
  }

  // [백엔드 수정] 아티스트 연결을 바꾸면 공연 정보 '아티스트' 칸도 서버 기준으로 갱신.
  Future<void> _refreshArtistField() async {
    final ticketId = _ticketId;
    if (ticketId == null) return;
    try {
      final label = (await _ticketService.getTicket(
        ticketId,
      )).concert?.artistLabel;
      final info = _ticketInfo;
      if (!mounted || label == null || info == null) return;
      final updated = info.copyWith(
        extraFields: {...info.extraFields, '아티스트': label},
      );
      setState(() => _ticketInfo = updated);
      widget.onTicketInfoChanged?.call(updated);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final canvas = _ScrapbookCanvas(
      layoutKey: _ticketId ?? 'local_after_${widget.concertTitle}',
      concertTitle: widget.concertTitle,
      ticketInfo: _ticketInfo,
      reviewText: _ticketInfo?.review,
      onReviewChanged: _saveReviewInline,
      pageLayout: _ticketInfo?.pageLayout,
      legacyPhotoUrls: _ticketInfo?.concertPhotoUrls ?? const <String>[],
      uploadingPhotos: _uploadingPhotos,
      onPickPhotos: _ticketId == null ? null : _pickAndUploadPhotos,
      onLayoutChanged: _ticketId == null ? null : _onLayoutChanged,
      setlistTicketId: _ticketId,
      concertId: _ticketInfo?.concertId,
      initialTimetableLoad: _preloadedTimetable,
      initialSetlistLoad: _preloadedSetlist,
      pageBoundaryKey: widget.pageBoundaryKey,
      issueNumber: widget.issueNumber,
      onOpenBeforePage: widget.onOpenBeforePage,
      onArtistIdentityChanged: _refreshArtistField,
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
  // [백엔드 수정] 아티스트 연결 수정 링크 노출 여부(공유 캡처에선 숨김).
  final bool canFixIdentity;
  // [백엔드 수정] 연결을 바꾼 뒤 공연 정보 '아티스트' 칸 갱신용.
  final VoidCallback? onIdentityChanged;

  const _RealSetlistContent({
    required this.ticketId,
    this.ink = _kraftInk,
    this.initialLoad,
    required this.selection,
    this.onEditorReady,
    this.canFixIdentity = false,
    this.onIdentityChanged,
  });

  @override
  State<_RealSetlistContent> createState() => _RealSetlistContentState();
}

class _RealSetlistContentState extends State<_RealSetlistContent> {
  static final Map<String, RealSetlistResponse> _cache = {};

  final ConcertDetailService _service = ConcertDetailService();
  List<SongEntry>? _songs;
  List<String> _artistNames = const [];
  // [백엔드 수정] 셋리가 빈 아티스트별 상태(빈 화면 문구용).
  RealSetlistResponse? _response;
  bool _isUserEdited = false;
  // 연결 수정 후 서버가 다시 채우는 동안.
  bool _refilling = false;

  @override
  void initState() {
    super.initState();
    widget.onEditorReady?.call(_openEditor);
    final ticketId = widget.ticketId;
    final cached = ticketId == null ? null : _cache[ticketId];
    if (cached != null) {
      _apply(ticketId!, cached);
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
      setState(() => _apply(ticketId, res));
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
    try {
      for (var attempt = 0; attempt < 10; attempt++) {
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        try {
          final res = await _service.getRealSetlist(ticketId);
          if (!mounted) return;
          if (res.songs.isNotEmpty) {
            setState(() => _apply(ticketId, res));
            return;
          }
          // 상태만 바뀐 경우도 반영.
          if (_statusKey(res) != _statusKey(_response)) {
            setState(() => _apply(ticketId, res));
          }
        } on ApiException catch (_) {
        } catch (_) {}
      }
    } finally {
      if (mounted && _refilling) setState(() => _refilling = false);
    }
  }

  // 앙코르 구분선/아티스트별 그룹핑은 build에서 처리.
  void _apply(String ticketId, RealSetlistResponse res) {
    _songs = res.songs;
    _artistNames = res.artistNames;
    _response = res;
    _isUserEdited = res.isUserEdited;
    _cache[ticketId] = res;
  }

  // [백엔드 수정] 아티스트 연결 수정 신규 - 바꾸면 서버가 자동으로 채운 실제 셋리를 지우고
  // 다음 조회 때 새 연결로 다시 채우므로, 다시 불러온 뒤 채워질 때까지 짧게 재확인.
  VoidCallback? _fixIdentityFor(String? artist) {
    final ticketId = widget.ticketId;
    if (!widget.canFixIdentity || ticketId == null || artist == null) {
      return null;
    }
    // 직접 고친 셋리는 연결을 바꿔도 그대로라 숨김.
    if (_isUserEdited) return null;
    return () => ArtistIdentitySheet.show(
      context,
      artist: artist,
      allowSongSearch: false,
      onLoad: () => _service.getIdentityCandidates(ticketId, artist),
      onPick: (candidate) async {
        await _service.changeArtistIdentity(
          ticketId,
          artist: artist,
          candidate: candidate,
          noArtist: candidate == null,
        );
        widget.onIdentityChanged?.call();
        final res = await _service.getRealSetlist(ticketId);
        if (!mounted) return;
        setState(() {
          _apply(ticketId, res);
          _refilling = res.songs.isEmpty && candidate != null;
        });
        if (_refilling) unawaited(_pollForUpdate(ticketId));
      },
    );
  }

  static String _statusKey(RealSetlistResponse? res) => [
    for (final s in res?.artistStatuses ?? const <ArtistSetlistStatus>[])
      '${s.artist}:${s.state}:${s.topSong}',
  ].join('|');

  Widget _buildEmptyState({VoidCallback? onFixIdentity, String? artist}) {
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
          SetlistEmptyMessage(
            status: _response?.statusFor(artist),
            refilling: _refilling,
            ink: widget.ink,
          ),
          if (onFixIdentity != null && !_refilling) ...[
            const SizedBox(height: 8),
            _RealFixIdentityLink(ink: widget.ink, onTap: onFixIdentity),
          ],
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
        setState(() => _apply(ticketId, res));
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
    if (songs.isEmpty && _artistNames.length <= 1) {
      final soloArtist = _artistNames.length == 1 ? _artistNames.first : null;
      return _buildEmptyState(
        onFixIdentity: _fixIdentityFor(soloArtist),
        artist: soloArtist,
      );
    }

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
      // 단독 공연은 song.artist가 비어있는 옛날 데이터가 많아서, 콘서트에
      // 등록된 아티스트(정확히 1명)를 검색용 폴백으로 씀.
      final fallbackArtist = allArtists.length == 1 ? allArtists.first : null;
      final onFix = _fixIdentityFor(fallbackArtist);
      if (songs.isEmpty) {
        return _buildEmptyState(onFixIdentity: onFix, artist: fallbackArtist);
      }
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._buildRealSongRows(
              context,
              songs,
              widget.ink,
              selection: widget.selection,
              fallbackArtist: fallbackArtist,
            ),
            if (onFix != null) ...[
              const SizedBox(height: 4),
              _RealFixIdentityLink(ink: widget.ink, onTap: onFix),
            ],
          ],
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
        fixIdentityFor: _fixIdentityFor,
        refilling: _refilling,
        statusFor: (artist) => _response?.statusFor(artist),
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
  // [백엔드 수정] 아티스트별 연결 수정 진입(null이면 링크 숨김).
  final VoidCallback? Function(String? artist) fixIdentityFor;
  final bool refilling;
  final ArtistSetlistStatus? Function(String? artist)? statusFor;

  const _RealSetlistGroupedByArtist({
    required this.groups,
    this.ink = _kraftInk,
    required this.selection,
    required this.fixIdentityFor,
    this.refilling = false,
    this.statusFor,
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
              onFixIdentity: widget.fixIdentityFor(widget.groups[g].key),
              refilling: widget.refilling,
              status: widget.statusFor?.call(widget.groups[g].key),
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
  final VoidCallback? onFixIdentity;
  final bool refilling;
  final ArtistSetlistStatus? status;

  const _RealSetlistArtistSection({
    required this.artistName,
    required this.songs,
    required this.expanded,
    required this.onTap,
    this.ink = _kraftInk,
    required this.selection,
    this.onFixIdentity,
    this.refilling = false,
    this.status,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (songs.isEmpty)
                  SetlistEmptyMessage(
                    status: status,
                    refilling: refilling,
                    ink: ink,
                    fontSize: 11.5,
                    alignment: WrapAlignment.start,
                  )
                else
                  ..._buildRealSongRows(
                    context,
                    songs,
                    ink,
                    selection: selection,
                  ),
                if (onFixIdentity != null) ...[
                  const SizedBox(height: 4),
                  _RealFixIdentityLink(ink: ink, onTap: onFixIdentity!),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

// [백엔드 수정] 실제 셋리 아티스트 연결 수정 링크 신규.
class _RealFixIdentityLink extends StatelessWidget {
  final Color ink;
  final VoidCallback onTap;

  const _RealFixIdentityLink({required this.ink, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: UnderlinedText(
        '다른 아티스트예요?',
        style: TextStyle(
          fontSize: context.sp(10.5),
          fontWeight: FontWeight.w600,
          color: ink.withValues(alpha: 0.6),
        ),
      ),
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
// 타이핑할 수 있습니다. 배치/크기/회전은 티켓 page_layout(캔버스 폭 = 1 정규화
// 좌표)으로 서버에 저장하고, 기기에는 오프라인용 캐시만 둡니다.
// =============================================================================

const Color _kraftInk = Color(0xFF463C2E);

/// 공연 제목 글꼴(기본 글꼴).
/// 태블릿(짧은 변 600dp 이상) 여부. 제목/하단 표시를 태블릿에서만 따로 조정할 때 씀.
bool _isTablet(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >=
    OrientationPolicy.tabletShortestSideThreshold;

/// 공연 제목 글꼴(기본 글꼴). 태블릿은 0.85배.
TextStyle _handTitle(BuildContext context) => TextStyle(
  fontSize: context.sp(_isTablet(context) ? 24 * .85 : 24),
  fontWeight: FontWeight.w800,
  color: _kraftInk,
  height: 1.15,
);

/// 두 줄로 넘어가는 제목은 두 줄 길이가 가장 비슷해지는 띄어쓰기에서 줄바꿈.
/// 한 줄에 들어가거나 알맞은 자리가 없으면 그대로.
String _balancedTitle(
  String title,
  TextStyle style,
  double maxWidth,
  TextScaler textScaler,
) {
  if (maxWidth <= 0 || title.contains('\n')) return title;
  double widthOf(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  if (widthOf(title) <= maxWidth) return title;
  final words = title.split(' ');
  String? best;
  var bestWidth = double.infinity;
  for (var i = 1; i < words.length; i++) {
    final first = words.sublist(0, i).join(' ');
    final second = words.sublist(i).join(' ');
    final wider = math.max(widthOf(first), widthOf(second));
    if (wider <= maxWidth && wider < bestWidth) {
      bestWidth = wider;
      best = '$first\n$second';
    }
  }
  return best ?? title;
}

/// 메모지 한 장의 세션 배치 상태. offset은 캔버스 내 절대 위치(좌상단,
/// 회전/확대 적용 전 기준).
class _MemoTransform {
  Offset offset = Offset.zero;
  double scale = 1;
  double rotation = 0;
  bool placed = false; // 기본 위치가 한 번 설정됐는지.
  bool deleted = false;

  /// 유저가 직접 옮긴 메모. 사진 추가로 자동 재배치해도 그대로 둠.
  bool pinned = false;

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
  double minScale = 0.4,
}) {
  if (size == Size.zero || canvasW <= 0 || canvasH <= minTop) return scale;
  final cosA = math.cos(rotation).abs();
  final sinA = math.sin(rotation).abs();
  final unitAabbW = size.width * cosA + size.height * sinA;
  final unitAabbH = size.width * sinA + size.height * cosA;
  final maxScaleW = unitAabbW <= 0 ? scale : canvasW / unitAabbW;
  final maxScaleH = unitAabbH <= 0 ? scale : (canvasH - minTop) / unitAabbH;
  final maxScale = math.min(3.2, math.min(maxScaleW, maxScaleH));
  return scale.clamp(math.min(minScale, maxScale), maxScale).toDouble();
}

const List<String> _defaultScrapZOrder = ['poster'];

/// 사진 추가 / 자동 배치로 다시 배치할 때 자유메모를 초기화할지 (false면 확인창 없이 그대로 둠).
const bool _resetMemosOnRelayout = true;

/// 공연후 페이지 사진 하나 (page_layout의 photo 아이템과 대응).
class _AfterPhoto {
  final String id;
  final String url;
  final String? thumbUrl;
  final int width;
  final int height;
  final String? takenAt;
  final double? quality;

  const _AfterPhoto({
    required this.id,
    required this.url,
    this.thumbUrl,
    required this.width,
    required this.height,
    this.takenAt,
    this.quality,
  });

  double get aspect => height <= 0 ? 1 : width / height;

  _AfterPhoto withSize(Size size) => _AfterPhoto(
    id: id,
    url: url,
    thumbUrl: thumbUrl,
    width: size.width.round(),
    height: size.height.round(),
    takenAt: takenAt,
    quality: quality,
  );

  static _AfterPhoto? fromItem(PageLayoutItem item) {
    final url = item.ref;
    if (url == null || url.isEmpty) return null;
    final meta = item.photo;
    return _AfterPhoto(
      id: item.id,
      url: url,
      thumbUrl: meta?.thumbUrl,
      width: meta?.w ?? 1,
      height: meta?.h ?? 1,
      takenAt: meta?.takenAt,
      quality: meta?.quality,
    );
  }

  PageLayoutPhoto toMeta() => PageLayoutPhoto(
    w: math.max(1, width),
    h: math.max(1, height),
    thumbUrl: thumbUrl,
    takenAt: takenAt,
    quality: quality,
  );
}

String _photoMemoKey(String id) => 'photo_$id';
bool _isPhotoMemoKey(String key) => key.startsWith('photo_');
String _photoIdFromKey(String key) => key.substring('photo_'.length);

/// 자동 배치를 UI 스레드 밖(compute)에서 실행.
LayoutResult _autoLayoutTask(
  ({
    List<LayoutItem> items,
    LayoutCanvas canvas,
    int seed,
    LayoutWeights weights,
  })
  args,
) =>
    autoLayout(args.items, args.canvas, seed: args.seed, weights: args.weights);

/// 이미지 원본 비율(EXIF 회전 적용 후). 작게 디코딩해 방향만 확인하고 크기는
/// 원본 헤더 기준으로 맞춤.
Future<Size> _decodeOrientedSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final rawW = descriptor.width, rawH = descriptor.height;
  final codec = await descriptor.instantiateCodec(targetWidth: 64);
  final frame = await codec.getNextFrame();
  final decodedLandscape = frame.image.width >= frame.image.height;
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  final rawLandscape = rawW >= rawH;
  return decodedLandscape == rawLandscape
      ? Size(rawW.toDouble(), rawH.toDouble())
      : Size(rawH.toDouble(), rawW.toDouble());
}

/// 네트워크 사진의 실제 크기 (page_layout 이전에 올린 사진의 비율 확인용).
Future<Size?> _resolveNetworkImageSize(String url) async {
  final stream = _concertAfterImageProvider(
    url,
  ).resolve(const ImageConfiguration());
  final completer = Completer<Size?>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!completer.isCompleted) {
        completer.complete(
          Size(info.image.width.toDouble(), info.image.height.toDouble()),
        );
      }
      stream.removeListener(listener);
    },
    onError: (_, _) {
      if (!completer.isCompleted) completer.complete(null);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future.timeout(
    const Duration(seconds: 6),
    onTimeout: () => null,
  );
}

class _ScrapbookCanvas extends StatefulWidget {
  final String layoutKey;
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final String? reviewText;
  final Future<void> Function(String) onReviewChanged;

  /// 서버 배치. null이면 아직 배치가 없는 페이지(기기 캐시 → 기존 사진 순으로 대체).
  final PageLayout? pageLayout;

  /// page_layout 도입 전 concert_photo_urls로 올린 사진. 처음 열 때 한 번 자동 배치로 옮김.
  final List<String> legacyPhotoUrls;
  final bool uploadingPhotos;
  final Future<List<_AfterPhoto>> Function()? onPickPhotos;
  final ValueChanged<PageLayout>? onLayoutChanged;
  final String? setlistTicketId;
  final String? concertId;
  final Future<timetable_model.TimeTableResponse>? initialTimetableLoad;
  final Future<RealSetlistResponse>? initialSetlistLoad;
  final GlobalKey? pageBoundaryKey;
  final int issueNumber;
  final Future<void> Function(Rect startRect, Widget collapsed)?
  onOpenBeforePage;
  // [백엔드 수정] 실제 셋리에서 아티스트 연결을 바꿨을 때.
  final VoidCallback? onArtistIdentityChanged;

  /// 공유 이미지용 읽기 전용 페이지 (편집 UI/제스처/저장 없음).
  final bool exportMode;

  /// [exportMode]에서 뒷면을 그릴지.
  final bool exportBack;

  const _ScrapbookCanvas({
    super.key,
    required this.layoutKey,
    required this.concertTitle,
    required this.ticketInfo,
    required this.reviewText,
    required this.onReviewChanged,
    required this.pageLayout,
    required this.legacyPhotoUrls,
    required this.uploadingPhotos,
    required this.onPickPhotos,
    required this.onLayoutChanged,
    required this.setlistTicketId,
    required this.concertId,
    required this.initialTimetableLoad,
    required this.initialSetlistLoad,
    this.pageBoundaryKey,
    this.issueNumber = 1,
    this.onOpenBeforePage,
    this.onArtistIdentityChanged,
    this.exportMode = false,
    this.exportBack = false,
  });

  @override
  State<_ScrapbookCanvas> createState() => _ScrapbookCanvasState();
}

class _ScrapbookCanvasState extends State<_ScrapbookCanvas>
    with SingleTickerProviderStateMixin {
  // 공유용 페이지는 build에서 안 써서 initState에서 생성.
  late final AnimationController _flip;
  late bool _showBack = widget.exportBack;
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
      // 뒷면으로 넘기면 편집 모드 해제.
      if (_showBack) {
        _edit = false;
        _activeMemoKey = null;
        _activeMemoOverDeleteZone = false;
      }
    });
    _syncDeleteOverlay();
    _flip.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() {});
    });
  }

  Widget _flippablePage(Widget front) {
    if (widget.exportMode) return _pageSheet(front, back: _showBack);
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
              child: _pageSheet(front, back: back),
            );
          },
        ),
      ),
    );
  }

  /// 페이지 종이(테두리/그림자) 안에 앞면 또는 뒷면.
  Widget _pageSheet(Widget front, {required bool back}) {
    return Container(
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
          ignoring: widget.exportMode || _flip.isAnimating,
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 제목 영역 폭([maxWidth]) 기준으로 줄바꿈을 맞춘 표시용 제목.
  String _titleFor(double maxWidth) => _balancedTitle(
    widget.concertTitle,
    _handTitle(context),
    maxWidth,
    MediaQuery.textScalerOf(context),
  );

  /// 하단 모드 표시 / 편집 도구 줄 높이 (태블릿은 조금 올림).
  double get _bottomBarInset => context.rs(_isTablet(context) ? 20 : 8);

  /// 하단 모드 표시. 잠금 모드면 오른쪽에 공유 버튼.
  Widget _modeBadge() {
    final badge = IgnorePointer(child: _ModeBadge(edit: _edit));
    return Positioned(
      bottom: _bottomBarInset,
      left: 0,
      right: 0,
      child: _edit
          ? Center(child: badge)
          : Row(
              children: [
                const Spacer(),
                badge,
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _ShareButton(onTap: _openShareSheet),
                  ),
                ),
              ],
            ),
    );
  }

  static const double _toolButtonHeight = 34;

  /// 자동 배치가 비워두는 아래쪽 띠 높이 (편집 도구 줄 + 여유).
  double get _bottomToolReserve =>
      _bottomBarInset + context.rs(_toolButtonHeight) + context.rs(6);

  /// 앞면 아래쪽 줄: 편집 모드면 모드 표시 양옆에 "사진 추가"/"자동 배치".
  /// 메모를 잡고 있는 동안엔 모드 표시만.
  Widget _frontEditBar() {
    if (widget.exportMode) return const SizedBox.shrink();
    if (!_edit || widget.onPickPhotos == null || _activeMemoKey != null) {
      return _modeBadge();
    }
    Widget tool(Widget button, Alignment alignment) => Expanded(
      child: Align(
        alignment: alignment,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: context.rs(140)),
          child: button,
        ),
      ),
    );
    return Positioned(
      bottom: _bottomBarInset,
      left: context.rs(10),
      right: context.rs(10),
      child: Row(
        children: [
          tool(
            _AddPhotoButton(
              height: _toolButtonHeight,
              busy: widget.uploadingPhotos || _autoLayoutRunning,
              onTap: _addPhotos,
            ),
            Alignment.centerRight,
          ),
          SizedBox(width: context.rs(8)),
          IgnorePointer(child: _ModeBadge(edit: _edit)),
          SizedBox(width: context.rs(8)),
          tool(
            _AddPhotoButton(
              height: _toolButtonHeight,
              busy: _autoLayoutRunning,
              onTap: _relayout,
              icon: Icons.auto_awesome_mosaic_outlined,
              label: '자동 배치',
            ),
            Alignment.centerLeft,
          ),
        ],
      ),
    );
  }

  Widget _backPage() {
    final sections = _backContents();
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 16, 8, context.rs(48)),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, c) => Text(
              _titleFor(c.maxWidth),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _handTitle(context),
            ),
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
    _flip = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _loadEnvelopeAccent();
    unawaited(_initLayout());
  }

  @override
  void didUpdateWidget(covariant _ScrapbookCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticketInfo?.posterImageUrl !=
        widget.ticketInfo?.posterImageUrl) {
      _loadEnvelopeAccent();
    }
    if (oldWidget.layoutKey != widget.layoutKey) {
      _t.clear();
      _z
        ..clear()
        ..addAll(_defaultScrapZOrder);
      _photos = [];
      _textItems = const [];
      _hasAppliedLayout = false;
      _refAspect = null;
      _textCanvasKey = GlobalKey();
      _layoutReady = false;
      _lastEmitted = null;
      unawaited(_initLayout());
    } else if (!identical(oldWidget.pageLayout, widget.pageLayout) &&
        widget.pageLayout != null &&
        !identical(widget.pageLayout, _lastEmitted)) {
      // 다른 기기/화면에서 바뀐 배치 (내가 방금 저장한 값의 반영은 무시).
      _pendingApply = widget.pageLayout;
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

  /// 서버/캐시 배치를 새로 적용할 때마다 새 키로 바꿔 텍스트 캔버스를 그 메모로 다시 만듦.
  GlobalKey<ConcertAfterTextCanvasState> _textCanvasKey = GlobalKey();

  /// 서버/캐시 배치를 한 번이라도 적용했는지 (텍스트 캔버스에 메모 목록을 넘길지).
  bool _hasAppliedLayout = false;
  bool _edit = false;
  String? _activeMemoKey;
  Timer? _pageLongPressTimer;
  Offset? _pageLongPressDownPosition;
  final Map<String, _MemoTransform> _t = {};

  /// 그리는 순서(마지막이 맨 앞). 만진 메모를 앞으로 올립니다.
  final List<String> _z = List<String>.from(_defaultScrapZOrder);

  // ─── page_layout 연동 ───
  List<_AfterPhoto> _photos = [];

  /// 자유메모(text) 아이템. 텍스트 캔버스가 바뀔 때마다 알려줌.
  List<PageLayoutItem> _textItems = const [];

  /// build에서 캔버스 크기가 정해지면 적용할 배치.
  PageLayout? _pendingApply;
  PageLayout? _lastEmitted;

  /// 저장된 배치를 적용했거나 새 페이지로 확정된 뒤에만 저장.
  bool _layoutReady = false;
  bool _needsLegacyMigration = false;
  bool _autoLayoutRunning = false;
  Size _canvasSize = Size.zero;

  /// 기준 배치(저장된 page_layout)의 캔버스 높이/폭. 화면에는 [_toView]로 맞춰 보여줌.
  double? _refAspect;
  double _titleTop = 0;

  String get _cacheKey => 'concert_after_page_layout_v1_${widget.layoutKey}';

  // 제스처 시작 시점 스냅샷.
  double _startScale = 1;
  double _startRot = 0;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  final ValueNotifier<int> _idleMemoFrame = ValueNotifier<int>(0);
  final ValueNotifier<int> _memoFrame = ValueNotifier<int>(0);
  bool _activeMemoOverDeleteZone = false;
  OverlayEntry? _deleteOverlayEntry;
  Future<void> Function(BuildContext context)? _setlistEditorLauncher;
  bool _openingSetlistEditor = false;

  Future<void> _openSetlistEditor() async {
    final launcher = _setlistEditorLauncher;
    if (launcher == null || _openingSetlistEditor) return;
    setState(() => _openingSetlistEditor = true);
    try {
      await launcher(context);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('편집 화면을 열지 못했어요. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) setState(() => _openingSetlistEditor = false);
    }
  }

  /// 지금 배치를 읽기 전용 페이지로 다시 그려 공유 시트에 넘김.
  /// 기준보다 납작하게 보이는 중이면(태블릿 가로) 기준 비율 높이로.
  void _openShareSheet() {
    final w = _canvasSize.width;
    if (w <= 0) return;
    final layout = _buildLayout();
    final pageSize = Size(
      w,
      math.max(_canvasSize.height, w * layout.canvasAspect),
    );
    final info = widget.ticketInfo;
    final posterUrl = info?.posterImageUrl;
    showConcertAfterShareSheet(
      context,
      pageSize: pageSize,
      frameScale: DiaryFrameScale.maybeWidgetOf(context),
      images: [
        if (posterUrl != null && posterUrl.isNotEmpty)
          _concertAfterImageProvider(posterUrl),
        for (final p in _photos) _concertAfterImageProvider(p.url),
      ],
      pending: [?widget.initialTimetableLoad, ?widget.initialSetlistLoad],
      title: widget.concertTitle,
      infoText: [
        if (info != null && info.date != null) info.formattedDate,
        if (info != null && info.venueName.isNotEmpty) info.venueName,
      ].join(' · '),
      fileStem: 'ticketdiary_${widget.setlistTicketId ?? 'page'}',
      pageBuilder: ({required bool back, required bool hideMemos}) =>
          _ScrapbookCanvas(
            key: ValueKey('share_${back}_$hideMemos'),
            layoutKey: widget.layoutKey,
            concertTitle: widget.concertTitle,
            ticketInfo: widget.ticketInfo,
            reviewText: hideMemos ? '' : widget.reviewText,
            onReviewChanged: (_) async {},
            pageLayout: hideMemos
                ? PageLayout(
                    canvasAspect: layout.canvasAspect,
                    items: [
                      for (final item in layout.items)
                        if (item.type != PageLayoutItemType.text) item,
                    ],
                  )
                : layout,
            legacyPhotoUrls: const [],
            uploadingPhotos: false,
            onPickPhotos: null,
            onLayoutChanged: null,
            setlistTicketId: widget.setlistTicketId,
            concertId: widget.concertId,
            initialTimetableLoad: widget.initialTimetableLoad,
            initialSetlistLoad: widget.initialSetlistLoad,
            issueNumber: widget.issueNumber,
            exportMode: true,
            exportBack: back,
          ),
    );
  }

  /// 서버 배치 → 없으면 기기 캐시 → 둘 다 없으면 기존 concert_photo_urls
  /// 사진을 자동 배치로 한 번 옮김.
  Future<void> _initLayout() async {
    final server = widget.pageLayout;
    if (server != null) {
      _pendingApply = server;
      _lastEmitted = server;
      return;
    }
    PageLayout? cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw != null) cached = PageLayout.tryParse(jsonDecode(raw));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      if (cached != null) {
        _pendingApply = cached;
        return;
      }
      _photos = [
        for (var i = 0; i < widget.legacyPhotoUrls.length; i++)
          if (widget.legacyPhotoUrls[i].isNotEmpty)
            _AfterPhoto(
              id: 'legacy$i',
              url: widget.legacyPhotoUrls[i],
              width: 1,
              height: 1,
            ),
      ];
      _needsLegacyMigration = _photos.isNotEmpty;
      _layoutReady = !_needsLegacyMigration;
    });
  }

  _AfterPhoto? _photoById(String id) {
    for (final p in _photos) {
      if (p.id == id) return p;
    }
    return null;
  }

  Size _memoBaseSize(String key, double w) {
    final bw = _memoBaseWidth(key, w);
    return Size(bw, bw / _memoAspectRatio(key));
  }

  /// 기준 배치 → 지금 화면 배율. 지금 캔버스가 기준보다 납작하면(태블릿 가로 모드 등)
  /// 제목 아래 영역 기준으로 통째로 축소해 가운데 정렬, 아니면 그대로.
  double get _viewScale {
    final w = _canvasSize.width;
    if (w <= 0) return 1;
    final top = _titleTop / w;
    final now = _canvasSize.height / w - top;
    final ref = (_refAspect ?? _canvasSize.height / w) - top;
    return ref <= 0 || now >= ref ? 1 : (now / ref).clamp(0.2, 1.0).toDouble();
  }

  PageLayoutItem _toView(PageLayoutItem item) {
    final s = _viewScale;
    if (s == 1) return item;
    final top = _titleTop / _canvasSize.width;
    return item.copyWith(
      cx: 0.5 + (item.cx - 0.5) * s,
      cy: top + (item.cy - top) * s,
      w: item.w * s,
    );
  }

  PageLayoutItem _toRef(PageLayoutItem item) {
    final s = _viewScale;
    if (s == 1) return item;
    final top = _titleTop / _canvasSize.width;
    return item.copyWith(
      cx: 0.5 + (item.cx - 0.5) / s,
      cy: top + (item.cy - top) / s,
      w: item.w / s,
    );
  }

  /// 정규화 좌표(중심, 폭) → 메모지 변환(좌상단 px, 배율).
  void _applyNormalized(
    String key,
    double w, {
    required double cx,
    required double cy,
    required double width,
    required double rotation,
  }) {
    final base = _memoBaseSize(key, w);
    _tf(key)
      ..scale = (width * w) / base.width
      ..rotation = rotation
      ..offset = Offset(cx * w - base.width / 2, cy * w - base.height / 2)
      ..placed = true
      ..deleted = false;
  }

  void _applyLayout(PageLayout layout, double w) {
    _refAspect = layout.canvasAspect;
    final items = [
      for (final item in [...layout.items]..sort((a, b) => a.z.compareTo(b.z)))
        _toView(item),
    ];
    _photos = [
      for (final item in items)
        if (item.type == PageLayoutItemType.photo) ?_AfterPhoto.fromItem(item),
    ];
    _textItems = [
      for (final item in items)
        if (item.type == PageLayoutItemType.text) item,
    ];
    _textCanvasKey = GlobalKey();
    _hasAppliedLayout = true;
    _t.clear();
    _z.clear();
    var hasPoster = false;
    for (final item in items) {
      final key = switch (item.type) {
        PageLayoutItemType.poster => 'poster',
        PageLayoutItemType.photo =>
          _photoById(item.id) == null ? null : _photoMemoKey(item.id),
        PageLayoutItemType.text => null,
      };
      if (key == null) continue;
      if (key == 'poster') hasPoster = true;
      _applyNormalized(
        key,
        w,
        cx: item.cx,
        cy: item.cy,
        width: item.w,
        rotation: item.rot,
      );
      _tf(key).pinned = item.pinned;
      _z.add(key);
    }
    // 저장된 배치에 포스터가 없으면 유저가 지운 것.
    if (!hasPoster && items.isNotEmpty) _tf('poster').deleted = true;
    _normalizeZOrder();
  }

  PageLayout _buildLayout() {
    final w = _canvasSize.width;
    final items = <PageLayoutItem>[];
    for (final key in _z) {
      final t = _t[key];
      if (t == null || t.deleted || !t.placed) continue;
      final base = _memoBaseSize(key, w);
      final center = t.offset + Offset(base.width / 2, base.height / 2);
      // 서버 검증 범위 안으로 맞춤.
      final cx = (center.dx / w).clamp(-0.5, 1.5).toDouble();
      final cy = (center.dy / w).clamp(-0.5, 5.0).toDouble();
      final width = (base.width * t.scale / w).clamp(0.01, 1.5).toDouble();
      final rot = math.atan2(math.sin(t.rotation), math.cos(t.rotation));
      if (key == 'poster') {
        items.add(
          PageLayoutItem(
            id: 'poster',
            type: PageLayoutItemType.poster,
            ref: widget.ticketInfo?.posterImageUrl,
            cx: cx,
            cy: cy,
            w: width,
            rot: rot,
            pinned: t.pinned,
          ),
        );
      } else if (_isPhotoMemoKey(key)) {
        final photo = _photoById(_photoIdFromKey(key));
        if (photo == null) continue;
        items.add(
          PageLayoutItem(
            id: photo.id,
            type: PageLayoutItemType.photo,
            ref: photo.url,
            cx: cx,
            cy: cy,
            w: width,
            rot: rot,
            pinned: t.pinned,
            photo: photo.toMeta(),
          ),
        );
      }
    }
    items.addAll(_textItems);
    _refAspect ??= _canvasSize.height / w;
    return PageLayout(
      canvasAspect: _refAspect!,
      items: [
        for (var i = 0; i < items.length; i++) _toRef(items[i]).copyWith(z: i),
      ],
    );
  }

  void _onTextsChanged(List<PageLayoutItem> items) {
    if (!mounted) return;
    _textItems = items;
    _persistLayout();
  }

  void _persistLayout() {
    if (widget.exportMode || !_layoutReady || _canvasSize.width <= 0) return;
    final layout = _buildLayout();
    _lastEmitted = layout;
    widget.onLayoutChanged?.call(layout);
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setString(_cacheKey, jsonEncode(layout)))
          .catchError((_) => false),
    );
  }

  /// page_layout 이전에 올린 사진: 실제 비율을 확인한 뒤 자동 배치로 한 번 옮김.
  Future<void> _migrateLegacyPhotos() async {
    final sizes = await Future.wait([
      for (final p in _photos) _resolveNetworkImageSize(p.url),
    ]);
    if (!mounted) return;
    _photos = [
      for (var i = 0; i < _photos.length; i++)
        sizes[i] == null ? _photos[i] : _photos[i].withSize(sizes[i]!),
    ];
    _layoutReady = true;
    await _runAutoLayout();
  }

  /// 유저가 고정한(직접 옮긴) 메모는 그대로 두고 나머지를 자동 배치.
  Future<void> _runAutoLayout() async {
    final w = _canvasSize.width, h = _canvasSize.height;
    if (w <= 0 || h <= 0 || _autoLayoutRunning) return;
    LayoutPin? pinOf(String key) {
      final t = _t[key];
      if (t == null || !t.pinned || !t.placed) return null;
      final base = _memoBaseSize(key, w);
      final center = t.offset + Offset(base.width / 2, base.height / 2);
      return LayoutPin(
        cx: center.dx / w,
        cy: center.dy / w,
        width: base.width * t.scale / w,
        rotation: t.rotation,
      );
    }

    final items = [
      if (!_isMemoDeleted('poster'))
        LayoutItem(
          id: 'poster',
          kind: LayoutItemKind.poster,
          aspect: _memoAspectRatio('poster'),
          fixedWidth: _memoBaseWidth('poster', w) / w,
          pin: pinOf('poster'),
        ),
      for (final p in _photos)
        LayoutItem(
          id: _photoMemoKey(p.id),
          kind: LayoutItemKind.photo,
          aspect: p.aspect,
          quality: p.quality ?? 0.5,
          pin: pinOf(_photoMemoKey(p.id)),
        ),
    ];
    // context가 필요한 값은 await 전에 계산.
    final reserved = [
      LayoutRect(0, 0, 1, _titleTop / w),
      LayoutRect(0, (h - _bottomToolReserve) / w, 1, h / w),
    ];
    setState(() => _autoLayoutRunning = true);
    try {
      final weights = await LayoutConfigService.weights();
      final result = await compute(_autoLayoutTask, (
        items: items,
        canvas: LayoutCanvas(aspect: h / w, reserved: reserved),
        seed: DateTime.now().millisecondsSinceEpoch % 100000,
        weights: weights,
      ));
      // 계산하는 동안 회전 등으로 캔버스가 바뀌었으면 결과를 버림.
      if (!mounted || _canvasSize != Size(w, h)) return;
      setState(() {
        // 새 기준 = 지금 화면이라 화면 좌표가 곧 기준 좌표 (자유메모 좌표도 그대로).
        _refAspect = h / w;
        for (final p in result.placements) {
          _applyNormalized(
            p.id,
            w,
            cx: p.cx,
            cy: p.cy,
            width: p.width,
            rotation: p.rotation,
          );
        }
        final order = [...result.placements]
          ..sort((a, b) => a.z.compareTo(b.z));
        final rest = _z.where((k) => !order.any((p) => p.id == k)).toList();
        _z
          ..clear()
          ..addAll(rest)
          ..addAll(order.map((p) => p.id));
      });
      _persistLayout();
    } finally {
      if (mounted) setState(() => _autoLayoutRunning = false);
    }
  }

  /// 다시 배치하기 전 자유메모 초기화 확인. 지울 메모가 없으면 묻지 않음.
  Future<bool> _confirmMemoReset() async {
    if (!_resetMemosOnRelayout) return true;
    if (!(_textCanvasKey.currentState?.hasTexts ?? false)) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('자유메모가 지워져요'),
        content: const Text('사진을 다시 배치하면 적어둔 자유메모가 모두 지워져요.\n계속할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('지우고 배치'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _resetMemosIfNeeded() {
    if (_resetMemosOnRelayout) _textCanvasKey.currentState?.clearAll();
  }

  /// 고정 안 된 사진/포스터만 다시 배치.
  Future<void> _relayout() async {
    if (_autoLayoutRunning || !await _confirmMemoReset() || !mounted) return;
    _resetMemosIfNeeded();
    _layoutReady = true;
    await _runAutoLayout();
  }

  void _togglePinned(String key) {
    final t = _tf(key);
    setState(() => t.pinned = !t.pinned);
    _persistLayout();
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
  }

  void _lockModeFromBlankSpace() {
    if (!_edit || _activeMemoKey != null) return;
    setState(() {
      _edit = false;
      _activeMemoOverDeleteZone = false;
      FocusManager.instance.primaryFocus?.unfocus();
    });
    _syncDeleteOverlay();
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
    final validKeys = <String>{
      ..._defaultScrapZOrder,
      for (final p in _photos) _photoMemoKey(p.id),
    };
    for (final key in validKeys) {
      if (!_z.contains(key)) _z.add(key);
    }
    _z.removeWhere((key) => !validKeys.contains(key));
  }

  void _bringFront(String k, {bool updateState = true}) {
    _normalizeZOrder();
    if (_z.isNotEmpty && _z.last == k) return;
    void apply() {
      _z.remove(k);
      _z.add(k);
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
      if (_isPhotoMemoKey(key)) {
        _photos.removeWhere((p) => p.id == _photoIdFromKey(key));
        _t.remove(key);
        _z.remove(key);
      } else {
        t.deleted = true;
      }
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

  double _titleSafeBottom(double width) {
    final maxWidth = math.max(0.0, width - 40);
    final painter = TextPainter(
      text: TextSpan(text: _titleFor(maxWidth), style: _handTitle(context)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
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
    for (var i = 0; i < _photos.length; i++) {
      final col = i % 3;
      final row = i ~/ 3;
      final dx = w * (.08 + col * .28);
      final dy = titleSafeBottom + context.rs(22) + row * h * .16;
      def(_photoMemoKey(_photos[i].id), dx, dy, 0);
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
      // 뒷면은 편집 모드 없음 (셋리스트는 제목 옆 편집 아이콘).
      editMode: false,
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

  final GlobalKey _beforePageThumbKey = GlobalKey();

  bool get _canOpenBeforePage =>
      !widget.exportMode && widget.onOpenBeforePage != null;

  // 뒷면 잉크(갈색)와, 크림 종이보다 한 톤 진한 바탕.
  Widget _beforePageThumbnail() => ConcertBeforeThumbnail(
    concertTitle: widget.concertTitle,
    issueNumber: widget.issueNumber,
    date: widget.ticketInfo?.date,
    posterUrl: widget.ticketInfo?.posterImageUrl,
    ink: _kraftInk,
    paper: _kraftInk.withValues(alpha: 0.06),
  );

  Future<void> _openBeforePage() async {
    final open = widget.onOpenBeforePage;
    final box =
        _beforePageThumbKey.currentContext?.findRenderObject() as RenderBox?;
    if (open == null || box == null || !box.hasSize) return;
    await open(
      box.localToGlobal(Offset.zero) & box.size,
      _beforePageThumbnail(),
    );
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
                // [백엔드 수정] "공연 전 신문" 썸네일 신규.
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '공연 전 신문',
                        style: TextStyle(fontSize: 11, color: _kraftInk),
                      ),
                      const SizedBox(height: 5),
                      GestureDetector(
                        key: _beforePageThumbKey,
                        behavior: HitTestBehavior.opaque,
                        onTap: _canOpenBeforePage ? _openBeforePage : null,
                        child: _beforePageThumbnail(),
                      ),
                      if (_canOpenBeforePage)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _openBeforePage,
                          child: const Padding(
                            padding: EdgeInsets.only(top: 5),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                '펼쳐보기 ›',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _kraftInk,
                                ),
                              ),
                            ),
                          ),
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
        // 칸보다 넓으면(아주 좁은 폰) 편집 + 음악앱 아이콘 묶음만 살짝 축소.
        trailing: widget.exportMode
            ? null
            : FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.setlistTicketId != null)
                      _BackEditChip(
                        busy: _openingSetlistEditor,
                        onTap: _openSetlistEditor,
                      ),
                    SetlistServiceIcon(selection: _setlistServiceSelection),
                  ],
                ),
              ),
        child: _editableBackSection(
          2,
          '실제 셋 리스트',
          _RealSetlistContent(
            ticketId: widget.setlistTicketId,
            ink: _kraftInk,
            initialLoad: setlistFuture,
            selection: _setlistServiceSelection,
            canFixIdentity: !widget.exportMode,
            onIdentityChanged: widget.onArtistIdentityChanged,
            onEditorReady: (launcher) {
              _setlistEditorLauncher = launcher;
            },
          ),
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
          'poster' => width * .25,
          _ => width * .26,
        };
  }

  double _memoAspectRatio(String key) => switch (key) {
    'poster' => 3 / 4,
    _ when _isPhotoMemoKey(key) =>
      _photoById(_photoIdFromKey(key))?.aspect ?? 1,
    _ => 1,
  };

  Size _memoFallbackSize(String key, double width) {
    final fallbackW = _memoBaseWidth(key, width);
    return Size(fallbackW, fallbackW / _memoAspectRatio(key));
  }

  /// 여러 장을 골라 올린 뒤, 고정된 메모는 그대로 두고 자동 배치.
  /// 자유메모 초기화는 사진을 고르기 전에 묻고, 실제로 추가됐을 때만 지움.
  Future<void> _addPhotos() async {
    final pick = widget.onPickPhotos;
    if (pick == null || _autoLayoutRunning) return;
    if (!await _confirmMemoReset() || !mounted) return;
    final added = await pick();
    if (added.isEmpty || !mounted) return;
    _resetMemosIfNeeded();
    setState(() {
      _photos = [..._photos, ...added];
      for (final p in added) {
        _z.add(_photoMemoKey(p.id));
      }
    });
    _layoutReady = true;
    await _runAutoLayout();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        final titleSafeBottom = _titleSafeBottom(w);
        if (_layoutReady &&
            _pendingApply == null &&
            !_autoLayoutRunning &&
            _canvasSize.width > 0 &&
            (_canvasSize.width - w).abs() > 0.5) {
          _pendingApply = _buildLayout();
        }
        _canvasSize = Size(w, h);
        _titleTop = titleSafeBottom;
        final pending = _pendingApply;
        if (pending != null) {
          _pendingApply = null;
          _applyLayout(pending, w);
          _layoutReady = true;
        }
        if (_needsLegacyMigration) {
          _needsLegacyMigration = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_migrateLegacyPhotos());
          });
        }
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
                  instant: widget.exportMode,
                ),
              ),
            ),
          for (final photo in _photos)
            if (!_isMemoDeleted(_photoMemoKey(photo.id)))
              _photoMemoKey(photo.id): _memo(
                _photoMemoKey(photo.id),
                baseW: _memoBaseWidth(_photoMemoKey(photo.id), w),
                canvasW: w,
                canvasH: h,
                titleSafeBottom: titleSafeBottom,
                child: _editableWidgetTone(
                  edit: _edit,
                  child: _PolaroidMemo(
                    aspectRatio: photo.aspect,
                    url: photo.url,
                    edit: _edit,
                    uploading: false,
                    onAdd: null,
                    instant: widget.exportMode,
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
                _titleFor(math.max(0.0, w - 40)),
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
                            initialItems: _hasAppliedLayout ? _textItems : null,
                            onTextsChanged: _onTextsChanged,
                            onTextsLoaded: (items) => _textItems = items,
                            memos: memoWidgets,
                          ),
                    ),
                  ),
                  ValueListenableBuilder<int>(
                    valueListenable: _memoFrame,
                    builder: (context, value, child) => _activeMemoDimOverlay(),
                  ),
                  _frontEditBar(),
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
      // 하한(0.4)은 손으로 핀치할 때만 적용.
      t.scale = _clampMemoScaleToCanvas(
        t.scale,
        t.rotation,
        size,
        canvasW,
        canvasH,
        minTop: titleSafeBottom,
        minScale: 0,
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
    final pinnable = key == 'poster' || _isPhotoMemoKey(key);
    final framed = _edit && pinnable
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              content,
              Positioned(
                top: -context.rs(10),
                right: -context.rs(10),
                // 메모 배율과 상관없이 같은 크기로 보이게.
                child: Transform.scale(
                  scale: 1 / t.scale.clamp(.4, 3.2),
                  child: _PinBadge(
                    pinned: t.pinned,
                    onTap: () => _togglePinned(key),
                  ),
                ),
              ),
            ],
          )
        : content;
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
                  t.pinned = true;
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
            child: framed,
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

/// 잠금 모드 하단 표시 옆 공유 버튼.
class _ShareButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ShareButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    // 잠금 표시 높이 이하로 (줄 높이 유지).
    final size = context.rs(20);
    return Semantics(
      button: true,
      label: '공유하기',
      child: GestureDetector(
        key: const ValueKey('after_share_button'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // 누르는 영역만 가로로 넓힘.
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.rs(6)),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: _kraftInk.withValues(alpha: 0.85),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.ios_share,
              size: context.rs(12),
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// 편집 모드에서 포스터/사진 모서리에 붙는 고정 표시. 누르면 고정/해제.
/// 고정된 메모는 "자동 배치"나 사진 추가로 다시 배치해도 그 자리에 남음.
class _PinBadge extends StatelessWidget {
  final bool pinned;
  final VoidCallback onTap;

  const _PinBadge({required this.pinned, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final size = context.rs(26);
    return Semantics(
      button: true,
      label: pinned ? '고정 해제' : '이 자리에 고정',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: pinned
                ? const Color(0xFFE53935)
                : const Color(0xFFF6E9CC).withValues(alpha: .92),
            shape: BoxShape.circle,
            border: Border.all(
              color: pinned ? Colors.white : _kraftInk.withValues(alpha: .35),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .2),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            pinned ? Icons.push_pin : Icons.push_pin_outlined,
            size: context.rs(15),
            color: pinned ? Colors.white : _kraftInk.withValues(alpha: .7),
          ),
        ),
      ),
    );
  }
}

class _AddPhotoButton extends StatelessWidget {
  final double height;
  final bool busy;
  final VoidCallback onTap;
  final IconData icon;
  final String label;

  const _AddPhotoButton({
    this.height = 38,
    required this.busy,
    required this.onTap,
    this.icon = Icons.add_photo_alternate_outlined,
    this.label = '사진 추가',
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
                // 좁은 화면에선 줄 전체를 축소.
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: context.rs(18), color: _kraftInk),
                        SizedBox(width: context.rs(6)),
                        Text(
                          label,
                          maxLines: 1,
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
    );
  }
}

class _PosterMemo extends StatelessWidget {
  final String? imageUrl;
  final Color paperColor;
  final bool instant;
  const _PosterMemo({
    required this.imageUrl,
    required this.paperColor,
    this.instant = false,
  });

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
                  instant: instant,
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
  final bool instant;

  const _PolaroidMemo({
    required this.aspectRatio,
    required this.url,
    required this.edit,
    required this.uploading,
    required this.onAdd,
    this.instant = false,
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
                            instant: instant,
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
/// 뒷면 칸 제목 옆 편집(연필) 아이콘. 누르면 바로 편집 화면을 엶.
/// 크기는 옆 음악앱 아이콘([SetlistServiceIcon])과 같음(16 + 여백 4).
class _BackEditChip extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;

  const _BackEditChip({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '셋리스트 편집',
    child: Material(
      color: Colors.transparent,
      child: InkResponse(
        onTap: busy ? null : onTap,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.all(4),
          // 편집 화면이 열려 있는 동안(busy)은 흐리게.
          child: Icon(
            Icons.edit_outlined,
            size: 16,
            color: _kraftInk.withValues(alpha: busy ? .35 : .85),
          ),
        ),
      ),
    ),
  );
}

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
        // 편집 / 음악앱 아이콘은 제목 바로 옆, 칸이 좁으면 제목 아래 줄로 내려감.
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: _kraftInk,
              ),
            ),
            ?trailing,
          ],
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
