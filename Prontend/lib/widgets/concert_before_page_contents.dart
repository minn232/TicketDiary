import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/ticket_info.dart';
import '../services/api_client.dart';
import '../services/app_settings_store.dart';
import '../services/concert_detail_service.dart';

/// 공연 전(오버레이/스크린 공용) 페이지 내부 콘텐츠.
///
/// - 제목/서브 타이틀
/// - 2x2 포스트잇(공연정보/타임테이블/D-day/예상 셋리스트)
///
/// NOTE
/// - 오버레이에서는 [postItOpacity]에 애니메이션을 넘기면 포스트잇이 Fade-in 됩니다.
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
    final postItBody = _PostItGrid(
      concertTitle: concertTitle,
      ticketInfo: ticketInfo,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          concertTitle,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        Text(
          '공연 전',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: Colors.black.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(height: 15),
        Expanded(
          child: postItOpacity == null
              ? postItBody
              : FadeTransition(opacity: postItOpacity!, child: postItBody),
        ),
        if (showCloseHint) ...[
          const SizedBox(height: 11),
          Text(
            '닫기: 포스트잇이 있는 페이지 바깥(포스터/불투명 영역)을 눌러주세요.',
            style: TextStyle(
              fontSize: 12,
              color: Colors.black.withValues(alpha: 0.45),
            ),
          ),
        ],
      ],
    );
  }
}

class _PostItGrid extends StatefulWidget {
  final String concertTitle;
  final TicketInfo? ticketInfo;

  const _PostItGrid({required this.concertTitle, this.ticketInfo});

  @override
  State<_PostItGrid> createState() => _PostItGridState();
}

/// 타임테이블/예상 셋리스트 포스트잇의 조회 상태.
/// - [loading]: 조회 중(응답 대기)
/// - [empty]: 조회는 끝났는데 아직 등록된 데이터가 없음(백엔드 404) — "미정"
/// - [disabled]: 예상 셋리스트 표시 설정이 꺼져 있음(백엔드 403)
/// - [error]: 그 외 실패(500, 네트워크 오류 등) — 상태 코드를 같이 보여줌
/// - [loaded]: 정상적으로 데이터를 받아옴
enum _FetchStatus { loading, empty, disabled, error, loaded }

class _PostItGridState extends State<_PostItGrid> {
  final ConcertDetailService _service = ConcertDetailService();

  List<TimetableEntry> _fetchedTimetable = const [];
  _FetchStatus _timetableStatus = _FetchStatus.loading;
  int? _timetableErrorCode;

  List<String> _fetchedSetlist = const [];
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
  void didUpdateWidget(covariant _PostItGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticketInfo?.concertId != widget.ticketInfo?.concertId) {
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
    unawaited(_loadPreSetlist(concertId));
  }

  /// `GET /concerts/{concertId}/timetable`. 미등록(404)은 "미정", 그 외
  /// 실패는 상태 코드와 함께 오류로 표시합니다.
  Future<void> _loadTimetable(String concertId) async {
    try {
      final res = await _service.getTimetable(concertId);
      if (!mounted) return;
      setState(() {
        _fetchedTimetable = res.contents
            .map((e) => TimetableEntry(time: e.time, label: e.description))
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

  /// `GET /concerts/{concertId}/setlist/pre`. 유저의 `show_predicted_setlist`
  /// 설정이 꺼져있으면(403) "표시 꺼짐"으로, 미등록(404)은 "미정"으로, 그 외
  /// 실패는 상태 코드와 함께 오류로 표시합니다.
  Future<void> _loadPreSetlist(String concertId) async {
    try {
      final res = await _service.getPreSetlist(concertId);
      if (!mounted) return;
      setState(() {
        _fetchedSetlist = res.songs
            .map((s) => s.encore ? '${s.name} (앵콜)' : s.name)
            .toList();
        _presetlistStatus = _FetchStatus.loaded;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.statusCode == 403) {
          _presetlistStatus = _FetchStatus.disabled;
        } else if (e.statusCode == 404) {
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

  /// 상태별로 포스트잇에 보여줄 안내 위젯. [loaded]는 호출부에서 별도로
  /// 처리하므로 여기선 다루지 않습니다.
  Widget _statusText(_FetchStatus status, int? errorCode) {
    switch (status) {
      case _FetchStatus.loading:
        return const _UndecidedText(message: '조회 중');
      case _FetchStatus.empty:
        return const _UndecidedText();
      case _FetchStatus.disabled:
        return const _UndecidedText(message: '예상 셋리스트 표시가\n꺼져 있어요');
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
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      for (final entry in timetable)
        _TimeRow(time: entry.time, label: entry.label),
    ],
  );

  Widget _buildSetlistBody(bool hasConcertId) {
    if (!hasConcertId) {
      final local = widget.ticketInfo?.setlist ?? const [];
      return local.isEmpty
          ? const _UndecidedText()
          : _SetlistContent(setlist: local);
    }
    if (_presetlistStatus != _FetchStatus.loaded) {
      return _statusText(_presetlistStatus, _presetlistErrorCode);
    }
    return _fetchedSetlist.isEmpty
        ? const _UndecidedText()
        : _SetlistContent(setlist: _fetchedSetlist);
  }

  @override
  Widget build(BuildContext context) {
    const spacing = 15.0;
    final ticketInfo = widget.ticketInfo;
    final fields = ticketInfo?.displayFields ?? _placeholderFields;
    final dDayLabel = _dDayLabel(ticketInfo?.date);
    final hasConcertId = ticketInfo?.concertId != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _PostItNote(
                      title: '공연 정보',
                      color: const Color(0xFFFFD6E8),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _kv('공연명', widget.concertTitle),
                            const SizedBox(height: 6),
                            for (final field in fields) ...[
                              _kv(field.key, field.value),
                              const SizedBox(height: 6),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _PostItNote(
                      title: '타임테이블',
                      color: const Color(0xFFCFF5E7),
                      child: _buildTimetableBody(hasConcertId),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: spacing),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Center(
                      child: Transform.rotate(
                        angle: -25 * math.pi / 180,
                        child: _DDayStickerPostIt(label: dDayLabel),
                      ),
                    ),
                  ),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: _PostItNote(
                      title: '예상 셋 리스트',
                      color: const Color(0xFFD9E8FF),
                      child: _buildSetlistBody(hasConcertId),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static Widget _kv(String k, String v) {
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(
            k,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.black54,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            v,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _PostItNote extends StatelessWidget {
  final String title;
  final Color color;
  final Widget child;

  const _PostItNote({
    required this.title,
    required this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.black.withValues(alpha: 0.12),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(2, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(13, 13, 13, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 11),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// D-day를 스티커처럼 붙인 느낌으로 보여주는, 텍스트 크기에 맞춘 작은 포스트잇.
class _DDayStickerPostIt extends StatelessWidget {
  final String label;

  const _DDayStickerPostIt({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6A6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.black.withValues(alpha: 0.12),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(2, 4),
          ),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.08,
          color: Colors.black.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// 예상 셋 리스트 본문. 설정 > "예상 셋리 노출 여부"가 켜져 있으면
/// 스포일러 방지를 위해 블러 처리해서 보여줍니다.
class _SetlistContent extends StatelessWidget {
  final List<String> setlist;

  const _SetlistContent({required this.setlist});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppSettingsStore.instance,
      builder: (context, _) {
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final song in setlist)
              Text(song, style: const TextStyle(fontSize: 13)),
          ],
        );

        if (!AppSettingsStore.instance.showExpectedSetlist) return content;

        return ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: content,
        );
      },
    );
  }
}

/// 백엔드에 아직 데이터가 없을 때(타임테이블/셋리스트) 보여주는 안내 텍스트.
class _UndecidedText extends StatelessWidget {
  final String message;

  const _UndecidedText({this.message = '미정'});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Colors.black.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  final String time;
  final String label;

  const _TimeRow({required this.time, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          time,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}
