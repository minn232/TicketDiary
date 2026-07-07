import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/ticket_info.dart';
import '../services/app_settings_store.dart';

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
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        Text(
          '공연 전',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Colors.black.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: postItOpacity == null
              ? postItBody
              : FadeTransition(opacity: postItOpacity!, child: postItBody),
        ),
        if (showCloseHint) ...[
          const SizedBox(height: 10),
          Text(
            '닫기: 포스트잇이 있는 페이지 바깥(포스터/불투명 영역)을 눌러주세요.',
            style: TextStyle(
              fontSize: 11,
              color: Colors.black.withValues(alpha: 0.45),
            ),
          ),
        ],
      ],
    );
  }
}

class _PostItGrid extends StatelessWidget {
  final String concertTitle;
  final TicketInfo? ticketInfo;

  const _PostItGrid({required this.concertTitle, this.ticketInfo});

  /// 스캔된 정보가 없을 때 보여줄 예시용 placeholder.
  static const _placeholderFields = [
    MapEntry('공연장', '알 수 없는 공연장'),
    MapEntry('공연일', '0000.00.00'),
    MapEntry('예매처', '예매 링크'),
  ];

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

  @override
  Widget build(BuildContext context) {
    const spacing = 14.0;
    final fields = ticketInfo?.displayFields ?? _placeholderFields;
    final dDayLabel = _dDayLabel(ticketInfo?.date);
    final timetable = ticketInfo?.timetable ?? const [];
    final setlist = ticketInfo?.setlist ?? const [];

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
                            _kv('공연명', concertTitle),
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
                      child: timetable.isEmpty
                          ? const _UndecidedText()
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                for (final entry in timetable)
                                  _TimeRow(
                                    time: entry.time,
                                    label: entry.label,
                                  ),
                              ],
                            ),
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
                      child: setlist.isEmpty
                          ? const _UndecidedText()
                          : _SetlistContent(setlist: setlist),
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
          width: 44,
          child: Text(
            k,
            style: const TextStyle(
              fontSize: 11,
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
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
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
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 10),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
          fontSize: 28,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.0,
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
              Text(song, style: const TextStyle(fontSize: 12)),
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
  const _UndecidedText();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '미정',
        style: TextStyle(
          fontSize: 13,
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
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
