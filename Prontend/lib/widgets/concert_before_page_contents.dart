import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/setlist.dart';
import '../models/ticket_info.dart';
import '../services/api_client.dart';
import '../services/app_settings_store.dart';
import '../services/concert_detail_service.dart';
import 'pressable_scale.dart';
import 'responsive_text.dart';

/// "공연 전" 페이지 콘텐츠.
///
/// - 위: 공연명 + D-day 칩
/// - 아래: 공연 정보 / 타임테이블(세로 타임라인) / 예상 셋 리스트(트랙리스트)를
///   포스트잇 색을 입힌 카드로 나눠, 좌우로 스와이프(PageView)해서 한 장씩 봅니다.
/// - 카드 내용이 길어지면 카드 안에서 세로로 스크롤됩니다(텍스트 잘림 없음).
///
/// NOTE
/// - 오버레이에서는 [postItOpacity]에 애니메이션을 넘기면 콘텐츠가 Fade-in 됩니다.
/// - 일반 스크린에서는 null로 두면 즉시 표시됩니다.
/// - [ticketInfo]가 있으면 스캔된 티켓 정보(공연장/날짜/가격/좌석 등)를 그대로 보여주고,
///   없으면 예시용 placeholder 값을 보여줍니다.
class ConcertBeforePageContents extends StatelessWidget {
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final Animation<double>? postItOpacity;
  final bool showCloseHint;

  const ConcertBeforePageContents({
    super.key,
    required this.concertTitle,
    this.ticketInfo,
    this.postItOpacity,
    this.showCloseHint = true,
  });

  @override
  Widget build(BuildContext context) {
    final body = _ConcertBeforeBody(
      concertTitle: concertTitle,
      ticketInfo: ticketInfo,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 제목/D-day/"공연 전" 라벨은 순전히 표시용이라 히트테스트에서
        // 제외합니다(IgnorePointer) — 그래야 이 자리를 눌렀을 때 뒤에 겹친
        // 포스터의 "바깥 탭으로 닫기" 감지기까지 탭이 그대로 통과합니다.
        IgnorePointer(
          // D-day를 제목과 같은 Row에 형제로 두면, 제목이 몇 줄로 늘어나든
          // Row가 항상 칩만큼의 폭을 미리 비워두므로 절대 겹치지 않습니다.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  concertTitle,
                  style: TextStyle(
                    fontSize: context.sp(19),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _DDayChip(label: _dDayLabel(ticketInfo?.date)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        IgnorePointer(
          child: Text(
            '공연 전',
            style: TextStyle(
              fontSize: context.sp(14),
              fontWeight: FontWeight.w800,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: postItOpacity == null
              ? body
              : FadeTransition(opacity: postItOpacity!, child: body),
        ),
        if (showCloseHint) ...[
          const SizedBox(height: 10),
          // 카드 스와이프 영역과 고정된 안내 문구 사이의 경계를 명확히 합니다.
          Container(height: 1, color: Colors.black.withValues(alpha: 0.08)),
          const SizedBox(height: 10),
          IgnorePointer(
            child: Text(
              '닫기: 페이지 바깥(포스터 영역)을 눌러주세요.',
              style: TextStyle(
                fontSize: context.sp(12),
                color: Colors.black.withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 티켓/섹션 전반에서 쓰는 포인트 색(짙은 자주색 — "티켓 잉크" 느낌).
const Color _accent = Color(0xFF52406B);

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

class _ConcertBeforeBody extends StatefulWidget {
  final String concertTitle;
  final TicketInfo? ticketInfo;

  const _ConcertBeforeBody({required this.concertTitle, this.ticketInfo});

  @override
  State<_ConcertBeforeBody> createState() => _ConcertBeforeBodyState();
}

/// 타임테이블/예상 셋리스트 포스트잇의 조회 상태.
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
        _TimelineRow(
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
    final fields = [
      MapEntry('공연명', widget.concertTitle),
      ...(ticketInfo?.displayFields ?? _placeholderFields),
    ];
    final hasConcertId = ticketInfo?.concertId != null;

    // 포스트잇처럼 색을 입힌 카드 3장을 좌우로 스와이프해서 하나씩
    // 보여줍니다. 카드 내용이 길면 카드 안에서 세로 스크롤됩니다.
    return _SwipeableCards(
      pages: [
        _SectionCard(
          icon: Icons.confirmation_number_outlined,
          label: '공연 정보',
          color: const Color(0xFFFFD6E8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final field in fields)
                _InfoRow(label: field.key, value: field.value),
            ],
          ),
        ),
        _SectionCard(
          icon: Icons.schedule_outlined,
          label: '타임테이블',
          color: const Color(0xFFCFF5E7),
          child: _buildTimetableBody(hasConcertId),
        ),
        _SectionCard(
          icon: Icons.queue_music_rounded,
          label: '예상 셋 리스트',
          color: const Color(0xFFD9E8FF),
          child: _buildSetlistBody(hasConcertId),
        ),
      ],
    );
  }
}

/// 카드 여러 장을 좌우 스와이프(PageView)로 넘겨보는 컨테이너. 하단에
/// 현재 몇 번째 카드인지 보여주는 점 인디케이터를 둡니다.
class _SwipeableCards extends StatefulWidget {
  final List<Widget> pages;

  const _SwipeableCards({required this.pages});

  @override
  State<_SwipeableCards> createState() => _SwipeableCardsState();
}

class _SwipeableCardsState extends State<_SwipeableCards> {
  // 뷰포트 비율을 1.0보다 작게 두면 옆 카드가 양쪽 끝에 살짝 삐져나와
  // 보여서, 굳이 설명하지 않아도 "옆으로 넘길 수 있다"는 걸 바로
  // 알아챌 수 있습니다.
  final PageController _controller = PageController(viewportFraction: 0.9);
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 이 위젯은 오버레이가 작은 티켓 크기에서 전체 화면으로 확장되는
    // 애니메이션(520ms) 동안 계속 레이아웃되는데, 그 사이 뷰포트 폭이
    // 급격히 바뀌면서 PageView가 첫 페이지가 아닌 다른 페이지로 튀는
    // 경우가 있었습니다. 확장 애니메이션이 끝난 뒤 한 번 더 첫 페이지로
    // 고정해서 항상 "공연 정보"부터 보이도록 합니다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 560), () {
        if (mounted && _controller.hasClients && (_controller.page ?? 0) != 0) {
          _controller.jumpToPage(0);
          setState(() => _index = 0);
        }
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: PageView(
            controller: _controller,
            // PageScrollPhysics는 스와이프 속도와 무관하게 항상 현재
            // 페이지의 바로 옆(±1)까지만 이동하도록 스냅합니다 — 아무리
            // 빠르게 슬라이드해도 한 번에 카드 한 장만 넘어갑니다.
            physics: const PageScrollPhysics(),
            onPageChanged: (i) => setState(() => _index = i),
            children: widget.pages,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < widget.pages.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _index ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: i == _index
                      ? _accent
                      : _accent.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 포스트잇처럼 색을 입힌 카드 한 장(스와이프 페이지 하나). 내용이 짧으면
/// 카드가 그 내용 높이만큼만 차지하고(위에 붙고 아래는 비워둠), 내용이
/// 카드 영역보다 길어지면 카드 안에서 세로로 스크롤됩니다.
class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Widget child;

  const _SectionCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // PageView가 각 페이지에 고정된(tight) 높이를 강제하는데, 그 높이를
    // 그대로 Container에 넘기면 내용이 짧아도 카드가 항상 꽉 찬 높이로
    // 늘어납니다. Align이 그 고정 높이를 "이 안에서는 원하는 만큼만
    // 차지해도 됨"으로 풀어주고(loosen), 남는 공간은 투명하게 비워둡니다.
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        width: double.infinity,
        // 카드 사이 간격을 넉넉히 둬서, 옆 카드가 삐져나와 보일 때 서로
        // 붙어 보이지 않고 확실히 구분되도록 합니다.
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withValues(alpha: 0.10)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(icon: icon, label: label),
            const SizedBox(height: 12),
            // SingleChildScrollView는 스크롤 축(세로) 제약이 느슨하면
            // 자기 자식(child) 크기에 맞춰지고, 자식이 더 크면 주어진
            // 최대 높이로 잘려 그 안에서 스크롤됩니다. Flexible이 바로 그
            // "느슨한 최대 높이"를 만들어줍니다(Expanded였다면 항상 꽉
            // 채워서 내용이 짧아도 카드가 늘어남).
            Flexible(child: SingleChildScrollView(child: child)),
          ],
        ),
      ),
    );
  }
}

/// 섹션 제목(아이콘 + 라벨). 카드 자체가 색을 갖게 되어, 제목은 짙은
/// 무채색으로 두어 어떤 카드 색 위에서도 잘 읽히게 합니다.
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SectionHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.black.withValues(alpha: 0.65)),
        const SizedBox(width: 7),
        Text(
          label,
          style: TextStyle(
            fontSize: context.sp(16),
            fontWeight: FontWeight.w900,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}

/// 공연 정보 한 줄(라벨 고정폭 + 값). 값은 줄 수 제한 없이 필요한 만큼
/// 자유롭게 줄바꿈됩니다(더 이상 스크롤 금지 제약이 없으므로 잘릴 걱정 없음).
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            // [백엔드 수정]
            // 폰트와 같은 배율로 같이 커지도록 context.rs()로 바꿈.
            width: context.rs(62),
            child: Text(
              label,
              style: TextStyle(
                fontSize: context.sp(12.5),
                fontWeight: FontWeight.w700,
                color: Colors.black.withValues(alpha: 0.55),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: context.sp(15),
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 제목 옆에 붙는 D-day 칩(도장 느낌).
class _DDayChip extends StatelessWidget {
  final String label;

  const _DDayChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: _accent,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _accent.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.event_rounded, size: 14, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            label,
            softWrap: false, // "D-12"처럼 짧은 배지 텍스트라 줄바꿈되면 안 됩니다.
            style: TextStyle(
              fontSize: context.sp(15),
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// 타임테이블 한 줄: 왼쪽에 점+세로선으로 이어진 세로 타임라인, 오른쪽에
/// 시간/라벨.
class _TimelineRow extends StatelessWidget {
  final String time;
  final String label;
  final bool isLast;

  const _TimelineRow({
    required this.time,
    required this.label,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(top: 3),
                decoration: const BoxDecoration(
                  color: _accent,
                  shape: BoxShape.circle,
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 1.4,
                    color: _accent.withValues(alpha: 0.25),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: context.sp(14),
                      fontWeight: FontWeight.w900,
                      color: _accent,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: TextStyle(fontSize: context.sp(14.5), color: Colors.black87),
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
      children: _buildSongRows(songs, gap: 10),
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
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  expanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: context.rs(18),
                  color: _accent,
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(
                    artistName,
                    style: TextStyle(
                      fontSize: context.sp(14.5),
                      fontWeight: FontWeight.w900,
                      color: Colors.black87,
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
              bottom: 10,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _buildSongRows(songs, gap: 8),
            ),
          ),
      ],
    );
  }
}

/// 번호 + 곡 이름 한 줄(앙코르 표시는 _EncoreDivider가 대신함). 단독/
/// 아코디언 펼친 목록 둘 다 재사용.
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
          // [백엔드 수정]
          // 폰트와 같은 배율로 같이 커지도록 context.rs()로 바꿈.
          width: context.rs(22),
          child: Text(
            '$index',
            softWrap: false,
            style: TextStyle(
              fontSize: context.sp(14),
              fontWeight: FontWeight.w900,
              color: _accent,
            ),
          ),
        ),
        Expanded(
          // [백엔드 수정]
          // 곡마다 "(앵콜)"을 반복해서 붙이지 않음 - _buildSongRows가
          // 앙코르 시작 지점에 _EncoreDivider를 한 번만 끼워 넣음.
          child: Text(
            song.name,
            style: TextStyle(fontSize: context.sp(14.5), color: Colors.black87),
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
      style: TextStyle(
        fontSize: context.sp(14),
        fontWeight: FontWeight.w700,
        color: Colors.black.withValues(alpha: 0.4),
      ),
    );
  }
}
