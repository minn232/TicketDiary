import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/setlist.dart';
import '../models/ticket_info.dart';
import '../services/api_client.dart';
import '../services/app_settings_store.dart';
import '../services/concert_detail_service.dart';
import 'fullscreen_poster.dart';
import 'poster_background.dart';
import 'pressable_scale.dart';
import 'responsive_text.dart';

/// "공연 전" 페이지 콘텐츠 — 신문 1면 디자인.
///
/// - 위: 신문 제호(masthead) + 발행일/D-day
/// - 헤드라인: 공연명
/// - 사진: 공연 포스터를 신문 사진처럼 프레임 + 캡션
/// - 기사: 공연 정보 / 타임테이블 / 예상 셋 리스트 순서로 세로 스크롤
///
/// NOTE
/// - 오버레이에서는 [postItOpacity]에 애니메이션을 넘기면 지면 전체가 Fade-in 됩니다.
/// - 일반 스크린에서는 null로 두면 즉시 표시됩니다.
/// - [ticketInfo]가 있으면 스캔된 티켓 정보(공연장/날짜/가격/좌석 등)를 그대로 보여주고,
///   없으면 예시용 placeholder 값을 보여줍니다.
class ConcertBeforePageContents extends StatelessWidget {
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final Animation<double>? postItOpacity;
  final bool showCloseHint;

  /// 이 티켓이 몇 번째로 등록됐는지(신문 "제 N 호"). 호출부에서 등록 순번을
  /// 넘겨줍니다. 단독 스크린 등 순번을 모르면 1로 둡니다.
  final int issueNumber;

  const ConcertBeforePageContents({
    super.key,
    required this.concertTitle,
    this.ticketInfo,
    this.postItOpacity,
    this.showCloseHint = true,
    this.issueNumber = 1,
  });

  @override
  Widget build(BuildContext context) {
    final paper = _ConcertBeforeBody(
      concertTitle: concertTitle,
      ticketInfo: ticketInfo,
      issueNumber: issueNumber,
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 지면(제호+기사) 전체를 하나로 페이드 인합니다. 지면이 아닌 빈
        // 자리를 눌렀을 때 뒤(오버레이의 "바깥 탭으로 닫기")까지 탭이
        // 전달되도록, 아래 신문 위젯들은 기본적으로 히트테스트를 붙잡지
        // 않는 순수 텍스트/장식으로 두었습니다(스크롤·셋리스트 미리보기
        // 같은 상호작용 요소만 예외).
        Expanded(
          child: postItOpacity == null
              ? paper
              : FadeTransition(opacity: postItOpacity!, child: paper),
        ),
        if (showCloseHint) ...[
          SizedBox(height: context.rs(10)),
          Container(height: 1, color: _ink.withValues(alpha: 0.15)),
          SizedBox(height: context.rs(8)),
          IgnorePointer(
            child: Text(
              '닫기: 페이지 바깥을 눌러주세요.',
              style: _serif(
                context,
                size: 12,
                color: _ink.withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ],
    );

    // 요청4: 페이지 전체(모든 구성요소)에 신문지 질감 — 뒤에 구겨짐/얼룩
    // 텍스처를 깔고(고정, 스크롤과 무관), 내용 위에 아주 옅은 구겨짐 그림자를
    // 한 겹 더 얹어 글자 위로도 종이 결이 지나가는 느낌을 줍니다. 둘 다
    // 히트테스트를 붙잡지 않아(포인터 무시) 탭/스크롤에 영향이 없습니다.
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _NewsprintPainter(foreground: false)),
        ),
        content,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _NewsprintPainter(foreground: true)),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// 신문 지면 공통 토큰(잉크색/세리프 글꼴)
// =============================================================================

/// 신문 잉크(거의 검정).
const Color _ink = Color(0xFF1A1A1A);

/// 신문지색(약간 회색끼가 도는 미색). 오버레이 카드 배경도 같은 색을 씁니다.
const Color _newsprint = Color(0xFFE9E6DC);

/// 영어/한글 모두 "공백(단어) 경계에서만" 줄바꿈되고, 한 단어(공백으로 구분된
/// 토큰)가 중간에서 쪼개지지 않도록 각 토큰 안 글자 사이에 WORD JOINER
/// (U+2060, 폭 없는 결합 문자)를 끼웁니다. 한글은 기본적으로 글자마다
/// 줄바꿈될 수 있어 단어가 잘려 보이던 것을 막습니다.
String _keepWords(String text) {
  const wj = '\u{2060}'; // WORD JOINER
  return text.split(' ').map((token) => token.split('').join(wj)).join(' ');
}

/// 세리프 글꼴(신문 느낌). 한글 글리프는 세리프 패밀리에 없으면 시스템
/// 기본 한글 폰트로 자연스럽게 폴백됩니다(별도 폰트 번들 없음).
const String _serifFamily = 'Georgia';
const List<String> _serifFallback = ['Times New Roman', 'Times', 'serif'];

/// 지면 전체에서 쓰는 세리프 텍스트 스타일 헬퍼.
TextStyle _serif(
  BuildContext context, {
  double size = 14,
  FontWeight weight = FontWeight.w400,
  Color color = _ink,
  double? height,
  double? letterSpacing,
  FontStyle? fontStyle,
}) {
  return TextStyle(
    fontFamily: _serifFamily,
    fontFamilyFallback: _serifFallback,
    fontSize: context.sp(size),
    fontWeight: weight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
    fontStyle: fontStyle,
  );
}

String _dDayLabel(DateTime? date) {
  if (date == null) return 'D-12';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(date.year, date.month, date.day);
  final diff = target.difference(today).inDays;
  if (diff > 0) return 'D-$diff';
  if (diff == 0) return 'D-DAY';
  return 'D+${-diff}';
}

/// 제호 아래 발행일 라인("2026년 8월 1일 토요일").
String _publishDateLabel(DateTime? date) {
  if (date == null) return '0000년 00월 00일';
  const weekday = ['월', '화', '수', '목', '금', '토', '일'];
  return '${date.year}년 ${date.month}월 ${date.day}일 '
      '${weekday[date.weekday - 1]}요일';
}

class _ConcertBeforeBody extends StatefulWidget {
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final int issueNumber;

  const _ConcertBeforeBody({
    required this.concertTitle,
    this.ticketInfo,
    required this.issueNumber,
  });

  @override
  State<_ConcertBeforeBody> createState() => _ConcertBeforeBodyState();
}

/// 타임테이블/예상 셋리스트 조회 상태.
/// - [loading]: 조회 중(응답 대기)
/// - [empty]: 조회는 끝났는데 아직 등록된 데이터가 없음(백엔드 404) — "미정"
/// - [error]: 그 외 실패(500, 네트워크 오류 등) — 상태 코드를 같이 보여줌
/// - [loaded]: 정상적으로 데이터를 받아옴
enum _FetchStatus { loading, empty, error, loaded }

class _ConcertBeforeBodyState extends State<_ConcertBeforeBody> {
  final ConcertDetailService _service = ConcertDetailService();

  List<TimetableEntry> _fetchedTimetable = const [];
  _FetchStatus _timetableStatus = _FetchStatus.loading;
  int? _timetableErrorCode;

  List<SongEntry> _fetchedSetlist = const [];
  _FetchStatus _presetlistStatus = _FetchStatus.loading;
  int? _presetlistErrorCode;

  /// 어떤 concertId로 이미 조회했는지 기억해, 같은 concertId로 다시
  /// build되어도 중복 요청하지 않습니다.
  String? _loadedConcertId;

  /// 스캔된 정보가 없을 때 보여줄 예시용 placeholder.
  static const _placeholderFields = [
    MapEntry('공연장', '알 수 없는 공연장'),
    MapEntry('공연일', '0000.00.00'),
    MapEntry('예매처', '예매 링크'),
  ];

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  @override
  void didUpdateWidget(covariant _ConcertBeforeBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticketInfo?.concertId != widget.ticketInfo?.concertId ||
        oldWidget.ticketInfo?.ticketId != widget.ticketInfo?.ticketId) {
      _loadedConcertId = null;
      _fetchedTimetable = const [];
      _fetchedSetlist = const [];
      _timetableStatus = _FetchStatus.loading;
      _presetlistStatus = _FetchStatus.loading;
      _timetableErrorCode = null;
      _presetlistErrorCode = null;
      _loadDetails();
    }
  }

  void _loadDetails() {
    final concertId = widget.ticketInfo?.concertId;
    // concertId가 없으면(로컬 예시 티켓 등) 애초에 조회할 대상이 없으므로
    // "로딩 중"으로 두지 않고 곧장 티켓에 담겨 있던 값(또는 "미정")을 씁니다.
    if (concertId == null) {
      setState(() {
        _timetableStatus = _FetchStatus.empty;
        _presetlistStatus = _FetchStatus.empty;
      });
      return;
    }
    if (concertId == _loadedConcertId) return;
    _loadedConcertId = concertId;
    unawaited(_loadTimetable(concertId));
    // [백엔드 수정]
    // 예상 셋리스트는 ticketId 기준으로 조회.
    final ticketId = widget.ticketInfo?.ticketId;
    if (ticketId != null) {
      unawaited(_loadPreSetlist(ticketId));
    } else {
      setState(() => _presetlistStatus = _FetchStatus.empty);
    }
  }

  /// `GET /concerts/{concertId}/timetable`. 미등록(404)은 "미정", 그 외
  /// 실패는 상태 코드와 함께 오류로 표시합니다.
  Future<void> _loadTimetable(String concertId) async {
    try {
      final res = await _service.getTimetable(concertId);
      if (!mounted) return;
      setState(() {
        // [백엔드 수정]
        // time/description → time(nullable)/event로 필드가 바뀜.
        // time이 없으면 빈 문자열로, stage가 있으면 event 앞에 붙여서 보여줌.
        _fetchedTimetable = res.contents
            .map(
              (e) => TimetableEntry(
                time: e.time ?? '',
                label: e.stage != null ? '${e.stage} · ${e.event}' : e.event,
              ),
            )
            .toList();
        _timetableStatus = _FetchStatus.loaded;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _timetableStatus = e.statusCode == 404
            ? _FetchStatus.empty
            : _FetchStatus.error;
        _timetableErrorCode = e.statusCode;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _timetableStatus = _FetchStatus.error);
    }
  }

  // [백엔드 수정]
  // /concerts/{concertId}/setlist/pre → /tickets/{ticketId}/setlist/pre.
  // 게스트도 이제 서버 ticketId를 가지므로, 예전에 있던 concertId 기준
  // 게스트 전용 폴백은 제거.
  /// `GET /tickets/{ticketId}/setlist/pre`. 미등록(404)은 "미정"으로,
  /// 그 외 실패는 상태 코드와 함께 오류로 표시합니다.
  Future<void> _loadPreSetlist(String ticketId) async {
    try {
      final res = await _service.getPreSetlist(ticketId);
      if (!mounted) return;
      setState(() {
        // [백엔드 수정]
        // artist 태그를 그대로 들고 있어야 페스티벌일 때 아티스트별로 묶어서
        // 보여줄 수 있어서, 여기서 문자열로 바로 뭉개지 않고 SongEntry
        // 그대로 둠(표시 문구 변환은 위젯에서).
        _fetchedSetlist = res.songs;
        _presetlistStatus = _FetchStatus.loaded;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.statusCode == 404) {
          _presetlistStatus = _FetchStatus.empty;
        } else {
          _presetlistStatus = _FetchStatus.error;
          _presetlistErrorCode = e.statusCode;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _presetlistStatus = _FetchStatus.error);
    }
  }

  /// 상태별로 보여줄 안내 위젯. [loaded]는 호출부에서 별도로 처리하므로
  /// 여기선 다루지 않습니다.
  Widget _statusText(_FetchStatus status, int? errorCode) {
    switch (status) {
      case _FetchStatus.loading:
        return const _UndecidedText(message: '조회 중');
      case _FetchStatus.empty:
        return const _UndecidedText();
      case _FetchStatus.error:
        // 네트워크 단절 등 HTTP 응답 자체가 없으면 ApiClient가 statusCode -1로
        // 던지므로, 양수 코드일 때만 코드를 그대로 보여줍니다.
        return _UndecidedText(
          message: errorCode != null && errorCode > 0
              ? '오류 ($errorCode)'
              : '오류 (연결 실패)',
        );
      case _FetchStatus.loaded:
        return const _UndecidedText();
    }
  }

  /// concertId가 없는(로컬 예시 등) 티켓은 서버 조회 자체를 안 하므로,
  /// 티켓에 이미 담겨 있던 값을 그대로 쓰고 없으면 "미정"을 보여줍니다.
  /// concertId가 있으면 조회 상태([_FetchStatus])에 따라 로딩 중/미정/오류/
  /// 실제 데이터를 구분해서 보여줍니다.
  Widget _buildTimetableBody(bool hasConcertId) {
    if (!hasConcertId) {
      final local = widget.ticketInfo?.timetable ?? const [];
      return local.isEmpty ? const _UndecidedText() : _timetableList(local);
    }
    if (_timetableStatus != _FetchStatus.loaded) {
      return _statusText(_timetableStatus, _timetableErrorCode);
    }
    return _fetchedTimetable.isEmpty
        ? const _UndecidedText()
        : _timetableList(_fetchedTimetable);
  }

  Widget _timetableList(List<TimetableEntry> timetable) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < timetable.length; i++)
        _NewsTimeRow(
          time: timetable[i].time,
          label: timetable[i].label,
          isLast: i == timetable.length - 1,
        ),
    ],
  );

  Widget _buildSetlistBody(bool hasConcertId) {
    if (!hasConcertId) {
      final local = widget.ticketInfo?.setlist ?? const [];
      return local.isEmpty
          ? const _UndecidedText()
          // [백엔드 수정]
          // 로컬(오프라인) 셋리스트는 아티스트 구분이 없는 단순 문자열
          // 목록이라, SongEntry로 감싸기만 하면 그대로 재사용 가능(항상
          // 단독 공연처럼 평범한 번호 목록으로 보임).
          : _SetlistNumbered(
              setlist: [for (final name in local) SongEntry(name: name)],
            );
    }
    if (_presetlistStatus != _FetchStatus.loaded) {
      return _statusText(_presetlistStatus, _presetlistErrorCode);
    }
    return _fetchedSetlist.isEmpty
        ? const _UndecidedText()
        : _SetlistNumbered(setlist: _fetchedSetlist);
  }

  @override
  Widget build(BuildContext context) {
    final ticketInfo = widget.ticketInfo;
    // 공연명은 제호로 이미 크게 나오므로 정보 표에서는 뺍니다(중복 제거).
    // 공연장(venue)은 요청5에 따라 "공연 정보" 섹션에서만 보여주고,
    // 여기(리드/포스터 캡션)에는 넣지 않습니다.
    final fields = ticketInfo?.displayFields ?? _placeholderFields;
    final hasConcertId = ticketInfo?.concertId != null;

    // 요청: 한 화면에 2×2로 모두 표시(가로 슬라이드/2배 폭 제거).
    //   왼위 포스터 · 왼아래 공연정보 · 오른위 예상 타임테이블 · 오른아래 셋리스트.
    // 제호(공연명 + 제 N 호)는 위에 그대로 두고, 그 아래를 2단×2행으로 나눕니다.
    // 세로가 넘칠 때만 FittedBox(scaleDown)로 지면을 줄여 한 화면에 담습니다.
    final gap = context.rs(14);
    final page = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Masthead(
          title: widget.concertTitle,
          issueNumber: widget.issueNumber,
          publishDate: _publishDateLabel(ticketInfo?.date),
          dday: _dDayLabel(ticketInfo?.date),
        ),
        SizedBox(height: context.rs(14)),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 왼쪽 단: 위=포스터, 아래=공연 정보
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SpreadPoster(
                      // 요청5: 공연장은 캡션에 넣지 않고 '공연 정보'에서만.
                      imageUrl: ticketInfo?.posterImageUrl,
                      caption: '공연 포스터',
                    ),
                    SizedBox(height: context.rs(16)),
                    _ArticleSection(
                      title: '공연 정보',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final field in fields)
                            _NewsInfoRow(label: field.key, value: field.value),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: gap),
              const _ColumnRule(),
              SizedBox(width: gap),
              // 오른쪽 단: 위=예상 타임테이블, 아래=예상 셋 리스트
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ArticleSection(
                      title: '예상 타임테이블',
                      child: _buildTimetableBody(hasConcertId),
                    ),
                    SizedBox(height: context.rs(16)),
                    _ArticleSection(
                      title: '예상 셋 리스트',
                      child: _buildSetlistBody(hasConcertId),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topCenter,
          child: SizedBox(width: constraints.maxWidth, child: page),
        );
      },
    );
  }
}

// =============================================================================
// 제호 / 헤드라인 / 사진 / 기사 섹션
// =============================================================================

/// 신문 제호(masthead): 발행 정보 라인 + 큰 제호(=공연 제목) + 코너 라벨/D-day,
/// 위아래를 굵은 괘선으로 감쌉니다. 제호는 공연 제목이라, 단어가 줄바꿈으로
/// 쪼개지지 않도록([_keepWords]) 하고 최대 2줄까지 허용합니다.
class _Masthead extends StatelessWidget {
  final String title;
  final int issueNumber;
  final String publishDate;
  final String dday;

  const _Masthead({
    required this.title,
    required this.issueNumber,
    required this.publishDate,
    required this.dday,
  });

  @override
  Widget build(BuildContext context) {
    final tiny = _serif(
      context,
      size: 10.5,
      weight: FontWeight.w600,
      color: _ink.withValues(alpha: 0.6),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 1, color: _ink),
        SizedBox(height: context.rs(6)),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // 요청1: 이 티켓이 몇 번째로 등록됐는지.
            Text('제 $issueNumber 호', style: tiny),
            Text(publishDate, style: tiny),
          ],
        ),
        SizedBox(height: context.rs(6)),
        // 요청2: 제호를 공연 제목으로. 요청3: 단어가 줄바꿈으로 분리되지 않게.
        Text(
          _keepWords(title),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _serif(
            context,
            size: 23,
            weight: FontWeight.w900,
            height: 1.12,
          ),
        ),
        SizedBox(height: context.rs(7)),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _DDayStamp(label: dday),
          ],
        ),
        SizedBox(height: context.rs(8)),
        // 제호 아래 이중 괘선(굵은 선 + 얇은 선).
        Container(height: 3, color: _ink),
        SizedBox(height: context.rs(2)),
        Container(height: 1, color: _ink),
      ],
    );
  }
}

/// 제호 오른쪽에 붙는 D-day 도장(테두리만 있는 신문 스탬프 느낌).
class _DDayStamp extends StatelessWidget {
  final String label;

  const _DDayStamp({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rs(10),
        vertical: context.rs(4),
      ),
      decoration: BoxDecoration(
        border: Border.all(color: _ink, width: 1.4),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        softWrap: false,
        style: _serif(
          context,
          size: 13,
          weight: FontWeight.w900,
          letterSpacing: context.rs(1),
        ),
      ),
    );
  }
}

/// 공연 포스터 이미지(신문 사진용). 없거나 로딩/실패 시 예시 그라데이션.
Widget _posterImage(String? url) {
  if (url == null || url.isEmpty) return const PosterGradientPlaceholder();
  return Image.network(
    url,
    fit: BoxFit.cover,
    webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
    loadingBuilder: (context, child, progress) =>
        progress == null ? child : const PosterGradientPlaceholder(),
    errorBuilder: (context, error, stackTrace) =>
        const PosterGradientPlaceholder(),
  );
}

/// 신문 단(段)을 나누는 세로 괘선. [IntrinsicHeight] Row 안에서 단 높이만큼
/// 늘어납니다.
class _ColumnRule extends StatelessWidget {
  const _ColumnRule();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, color: _ink.withValues(alpha: 0.25));
  }
}

/// 스프레드 가운데 상단의 포스터. 신문 사진처럼 얇은 검정 프레임 + 캡션 +
/// 확대 힌트 아이콘. 더블탭하면 전체화면으로 확대([showFullscreenPoster],
/// 소식 탭 포스터 확대와 동일). 단일 탭은 흡수해, 지면을 눌러 오버레이가
/// 닫히는 것과 헷갈리지 않게 합니다.
class _SpreadPoster extends StatelessWidget {
  final String? imageUrl;
  final String caption;

  const _SpreadPoster({required this.imageUrl, required this.caption});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {}, // 단일 탭 흡수(오버레이 닫힘 방지).
          onDoubleTap: () => showFullscreenPoster(context, imageUrl),
          child: Stack(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: _ink, width: 1.2),
                ),
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: SizedBox(
                    width: double.infinity,
                    child: _posterImage(imageUrl),
                  ),
                ),
              ),
              Positioned(
                right: context.rs(6),
                bottom: context.rs(6),
                child: Container(
                  padding: EdgeInsets.all(context.rs(4)),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    Icons.zoom_in,
                    size: context.rs(15),
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: context.rs(6)),
        Text(
          '▲ $caption',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _serif(
            context,
            size: 10.5,
            color: _ink.withValues(alpha: 0.6),
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }
}

/// 기사 섹션 한 덩어리: 세리프 소제목 + 오른쪽으로 이어지는 괘선, 그 아래 본문.
class _ArticleSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _ArticleSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: _serif(context, size: 15, weight: FontWeight.w900),
        ),
        SizedBox(height: context.rs(9)),
        child,
      ],
    );
  }
}

/// 공연 정보 한 줄. 좁은 단에서 값이 글자 단위로 쪼개지지 않도록, 라벨을 값
/// 위에 얹어(세로 배치) 값에 단 전체 폭을 주고, 값은 공백(단어) 경계에서만
/// 줄바꿈되도록 [_keepWords]를 씁니다.
class _NewsInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _NewsInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.rs(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: _serif(
              context,
              size: 11,
              weight: FontWeight.w700,
              color: _ink.withValues(alpha: 0.5),
            ),
          ),
          Text(
            _keepWords(value),
            style: _serif(context, size: 13.5, weight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// 타임테이블 한 줄: 시간(굵게) + 내용. 시간이 없으면 가운뎃점으로 표시.
class _NewsTimeRow extends StatelessWidget {
  final String time;
  final String label;
  final bool isLast;

  const _NewsTimeRow({
    required this.time,
    required this.label,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : context.rs(10)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: context.rs(52),
            child: Text(
              time.isEmpty ? '·' : time,
              style: _serif(context, size: 13.5, weight: FontWeight.w900),
            ),
          ),
          Expanded(
            child: Text(
              _keepWords(label),
              style: _serif(context, size: 14, weight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

// [백엔드 수정]
// 페스티벌(아티스트 2명 이상) 예상 셋리스트 지원 - setlist가 List<String>에서
// List<SongEntry>로 바뀜(artist 태그 포함). 아티스트별 아코디언 그룹핑은
// 아래 _SetlistGroupedByArtist 참고.
/// 예상 셋 리스트 본문.
/// 아티스트가 1명(또는 없음)이면 번호만 매긴 목록,
/// 페스티벌이면 아티스트별로 곡을 묶어서 아코디언.
/// 설정 > "예상 셋리 노출 여부"가 꺼져 있으면 스포일러 방지를 위해 블러 처리(단독/
/// 페스티벌 모두 동일 적용), 블러 상태에서 꾹 눌러서(long press) 누르고
/// 있는 동안만 미리보기 가능(떼면 다시 블러).
class _SetlistNumbered extends StatefulWidget {
  final List<SongEntry> setlist;

  const _SetlistNumbered({required this.setlist});

  @override
  State<_SetlistNumbered> createState() => _SetlistNumberedState();
}

class _SetlistNumberedState extends State<_SetlistNumbered> {
  /// 지금 꾹 눌러서 블러를 잠깐 풀어보고 있는 중인지.
  bool _peeking = false;

  void _setPeeking(bool value) {
    if (_peeking == value) return;
    setState(() => _peeking = value);
  }

  /// 아티스트 태그 기준으로 곡을 묶음(첫 등장 순서 유지). artist가 전부
  /// null이거나 서로 같으면 그룹이 1개뿐이라 단독 공연과 동일하게 취급됨.
  List<MapEntry<String?, List<SongEntry>>> _groupByArtist() {
    final groups = <String?, List<SongEntry>>{};
    for (final song in widget.setlist) {
      groups.putIfAbsent(song.artist, () => []).add(song);
    }
    return groups.entries.toList();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppSettingsStore.instance,
      builder: (context, _) {
        final groups = _groupByArtist();
        final content = groups.length > 1
            ? _SetlistGroupedByArtist(groups: groups)
            : _FlatNumberedSongs(songs: widget.setlist);

        if (AppSettingsStore.instance.showExpectedSetlist) return content;

        // 블러 상태: 꾹 누르고 있는 동안만(_peeking) 실제 내용을 보여주고,
        // 손을 떼거나(onLongPressEnd) 제스처가 중간에 취소되면(스크롤 등,
        // onLongPressCancel) 곧바로 다시 블러 처리합니다.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (_) => _setPeeking(true),
          onLongPressEnd: (_) => _setPeeking(false),
          onLongPressCancel: () => _setPeeking(false),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: _peeking
                ? KeyedSubtree(key: const ValueKey('clear'), child: content)
                : KeyedSubtree(
                    key: const ValueKey('blurred'),
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                      child: content,
                    ),
                  ),
          ),
        );
      },
    );
  }
}

// [백엔드 수정]
// (앵콜) 텍스트 제거.
List<Widget> _buildSongRows(List<SongEntry> songs, {required double gap}) {
  return [
    for (var i = 0; i < songs.length; i++)
      Padding(
        padding: EdgeInsets.only(bottom: i == songs.length - 1 ? 0 : gap),
        child: _SongRow(index: i + 1, song: songs[i]),
      ),
  ];
}

/// 단독 공연(또는 아티스트 구분이 없는) 예상 셋리 - 번호만 매긴 평범한 목록.
class _FlatNumberedSongs extends StatelessWidget {
  final List<SongEntry> songs;

  const _FlatNumberedSongs({required this.songs});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _buildSongRows(songs, gap: context.rs(9)),
    );
  }
}

// [백엔드 수정]
/// 페스티벌처럼 아티스트가 여럿일 때 - 이름을 쭉 나열해두고, 누른
/// 아티스트만 곡 목록이 펼쳐지는 아코디언.
/// 한 번에 하나만 펼쳐지고(다른 걸 누르면 이전 건 자동으로 접힘),
/// 펼칠 때 그 아티스트 위치로 화면을 스크롤.
class _SetlistGroupedByArtist extends StatefulWidget {
  final List<MapEntry<String?, List<SongEntry>>> groups;

  const _SetlistGroupedByArtist({required this.groups});

  @override
  State<_SetlistGroupedByArtist> createState() =>
      _SetlistGroupedByArtistState();
}

class _SetlistGroupedByArtistState extends State<_SetlistGroupedByArtist> {
  /// 지금 펼쳐진 아티스트의 인덱스(widget.groups 기준). null이면 아무도 안
  /// 펼쳐진 상태. 같은 걸 다시 누르면 접힘(toggle), 다른 걸 누르면 그쪽만
  /// 펼쳐짐(동시에 여러 개 펼쳐지지 않음).
  int? _expandedIndex;

  /// 아티스트 행마다 하나씩 - 펼칠 때 그 위치로 스크롤하기 위한 앵커.
  late final List<GlobalKey> _sectionKeys = [
    for (var _ in widget.groups) GlobalKey(),
  ];

  void _toggle(int index) {
    final willExpand = _expandedIndex != index;
    setState(() => _expandedIndex = willExpand ? index : null);
    if (!willExpand) return;

    // 펼침으로 인한 레이아웃 변경(곡 목록 높이만큼 늘어남)이 반영된 다음
    // 프레임에 스크롤해야 목표 위치가 정확합니다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _sectionKeys[index].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0, // 0 = 뷰포트 맨 위에 붙도록
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
            child: _ArtistAccordionSection(
              artistName: widget.groups[g].key ?? '아티스트 미상',
              songs: widget.groups[g].value,
              expanded: g == _expandedIndex,
              onTap: () => _toggle(g),
            ),
          ),
      ],
    );
  }
}

// [백엔드 수정]
/// 아코디언 한 칸: 아티스트 이름(눌러서 펼치기/접기),
/// 펼치면 그 아래에 이 아티스트만의 번호 매긴 곡 목록
class _ArtistAccordionSection extends StatelessWidget {
  final String artistName;
  final List<SongEntry> songs;
  final bool expanded;
  final VoidCallback onTap;

  const _ArtistAccordionSection({
    required this.artistName,
    required this.songs,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PressableScale(
          onTap: onTap,
          pressScale: 0.99,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: context.rs(6)),
            child: Row(
              children: [
                Icon(
                  expanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: context.rs(18),
                  color: _ink,
                ),
                SizedBox(width: context.rs(2)),
                Expanded(
                  child: Text(
                    _keepWords(artistName),
                    style: _serif(
                      context,
                      size: 14.5,
                      weight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: EdgeInsets.only(
              left: context.rs(24),
              top: 2,
              bottom: context.rs(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _buildSongRows(songs, gap: context.rs(8)),
            ),
          ),
      ],
    );
  }
}

/// 번호 + 곡 이름 한 줄. 단독/아코디언 펼친 목록 둘 다 재사용.
class _SongRow extends StatelessWidget {
  final int index;
  final SongEntry song;

  const _SongRow({required this.index, required this.song});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: context.rs(22),
          child: Text(
            '$index',
            softWrap: false,
            style: _serif(context, size: 14, weight: FontWeight.w900),
          ),
        ),
        Expanded(
          child: Text(
            _keepWords(song.name),
            style: _serif(context, size: 14.5, weight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

/// 백엔드에 아직 데이터가 없을 때(타임테이블/셋리스트) 보여주는 안내 텍스트.
class _UndecidedText extends StatelessWidget {
  final String message;

  const _UndecidedText({this.message = '미정'});

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: _serif(
        context,
        size: 14,
        weight: FontWeight.w700,
        color: _ink.withValues(alpha: 0.4),
      ),
    );
  }
}

/// 신문지 질감(요청4): 약간 회색끼 도는 바탕 + 은은한 얼룩(mottle) + 구겨짐
/// 주름(crease) + 미세한 종이 결(grain). [foreground]가 false면 내용 뒤에
/// 까는 바탕(색 채움 + 얼룩 + 주름 + 결)이고, true면 내용 위에 아주 옅게
/// 얹는 주름/비네팅만 그립니다(글자 위로도 종이 결이 지나가는 느낌).
/// 고정 시드라 리빌드 때 무늬가 흔들리지 않습니다.
class _NewsprintPainter extends CustomPainter {
  final bool foreground;

  const _NewsprintPainter({required this.foreground});

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(20260912);
    final rect = Offset.zero & size;

    if (!foreground) {
      // 바탕색(회색끼 도는 신문지).
      canvas.drawRect(rect, Paint()..color = _newsprint);

      // 은은한 얼룩(밝고 어두운 큰 원들을 아주 옅게 겹쳐 종이 얼룩 느낌).
      for (var i = 0; i < 16; i++) {
        final c = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
        final r = size.shortestSide * (0.12 + rnd.nextDouble() * 0.22);
        final dark = rnd.nextBool();
        final paint = Paint()
          ..shader = RadialGradient(
            colors: [
              (dark ? Colors.black : Colors.white)
                  .withValues(alpha: dark ? 0.035 : 0.05),
              const Color(0x00000000),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: r));
        canvas.drawCircle(c, r, paint);
      }
    }

    // 구겨짐 주름: 밝은 선 + 바로 옆 어두운 선(접힌 능선처럼 보이게).
    final creaseCount = foreground ? 5 : 9;
    for (var i = 0; i < creaseCount; i++) {
      final start = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      final angle = rnd.nextDouble() * math.pi * 2;
      final len = size.longestSide * (0.35 + rnd.nextDouble() * 0.55);
      final dir = Offset(math.cos(angle), math.sin(angle));
      final end = start + dir * len;
      final perp = Offset(-dir.dy, dir.dx);
      final lightA = foreground ? 0.03 : 0.06;
      final darkA = foreground ? 0.025 : 0.05;
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = Colors.white.withValues(alpha: lightA)
          ..strokeWidth = 1.1,
      );
      canvas.drawLine(
        start + perp * 1.3,
        end + perp * 1.3,
        Paint()
          ..color = Colors.black.withValues(alpha: darkA)
          ..strokeWidth = 1.0,
      );
    }

    if (!foreground) {
      // 미세한 종이 결(작은 점들).
      final grain = Paint();
      for (var i = 0; i < 260; i++) {
        final p = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
        grain.color = Colors.black.withValues(alpha: rnd.nextDouble() * 0.03);
        canvas.drawCircle(p, 0.6, grain);
      }
    } else {
      // 가장자리 비네팅(살짝 어둡게) — 오래된 신문지 느낌.
      final vignette = Paint()
        ..shader = RadialGradient(
          radius: 0.9,
          colors: [const Color(0x00000000), Colors.black.withValues(alpha: 0.05)],
          stops: const [0.75, 1.0],
        ).createShader(rect);
      canvas.drawRect(rect, vignette);
    }
  }

  @override
  bool shouldRepaint(covariant _NewsprintPainter old) =>
      old.foreground != foreground;
}
