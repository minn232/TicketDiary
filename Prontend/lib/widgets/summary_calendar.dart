import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'paper_style.dart';
import '../models/news_model.dart';
import '../services/sound_effect_service.dart';
import 'app_network_image.dart';

const _ink = Color(0xFF5C4033);
const _paper = Color(0xFFE5D3B9);
const _diaryPaper = Color(0xFFF4F1E1);
const _weekdayNames = ['일', '월', '화', '수', '목', '금', '토'];

class SummaryCalendar extends StatelessWidget {
  const SummaryCalendar({
    super.key,
    required this.tickets,
    required this.selection,
    this.news = const [],
    this.onNewsTap,
    this.onTicketTap,
  });
  final List<Map<String, dynamic>> tickets;
  final ValueNotifier<DateTime> selection;
  final List<NewsModel> news;
  final ValueChanged<NewsModel>? onNewsTap;
  final ValueChanged<Map<String, dynamic>>? onTicketTap;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DateTime>(
    valueListenable: selection,
    builder: (context, selected, _) {
      final month = DateTime(selected.year, selected.month);
      final days = DateTime(month.year, month.month + 1, 0).day;
      final offset = month.weekday % 7;
      final rows = ((days + offset) / 7).ceil();
      final now = DateTime.now();
      final grouped = <DateTime, List<Map<String, dynamic>>>{};
      // 관람 완료 공연은 결산 API의 ticket_details를 기준으로 표시합니다.
      // 소식 데이터와 달리 과거 관람 기록은 캘린더에 남아 있어야 합니다.
      for (final ticket in tickets) {
        final date = DateTime.tryParse('${ticket['date']}');
        if (date != null) {
          (grouped[DateTime(date.year, date.month, date.day)] ??= []).add(
            ticket,
          );
        }
      }
      for (final item in news) {
        void addNews(DateTime? value, String type, {int? day}) {
          if (value == null) return;
          final date = DateTime(value.year, value.month, value.day);
          if (type == 'ticketing' &&
              date.isBefore(DateTime(now.year, now.month, now.day))) {
            return;
          }
          (grouped[date] ??= []).add({'kind': type, 'news': item, 'day': day});
        }

        addNews(item.ticketingDate, 'ticketing');
        final start = item.concertDate;
        final end = item.concertEndDate ?? start;
        if (start != null && end != null) {
          final todayDate = DateTime(now.year, now.month, now.day);
          final endDate = DateTime(end.year, end.month, end.day);
          // 소식탭에서 이미 지나간 공연 카드를 보여주지 않으므로,
          // 캘린더에도 과거 공연 일정은 만들지 않습니다.
          if (!endDate.isBefore(todayDate)) {
            for (
              var day = 0;
              !DateTime(
                start.year,
                start.month,
                start.day + day,
              ).isAfter(DateTime(end.year, end.month, end.day));
              day++
            ) {
              addNews(
                DateTime(start.year, start.month, start.day + day),
                'concert',
                day: day + 1,
              );
            }
          }
        }
      }
      for (final date in grouped.keys.toList()) {
        final items = grouped[date]!;
        grouped[date] = [
          ...items.where((item) => item['kind'] == 'ticketing'),
          ...items.where((item) => item['kind'] != 'ticketing'),
        ];
      }
      final entries = grouped[selected] ?? [];
      final currentMonth = DateTime(now.year, now.month);
      final availableMonths = <DateTime>{currentMonth};
      for (final date in grouped.keys) {
        final candidate = DateTime(date.year, date.month);
        availableMonths.add(candidate);
      }
      final latestMonth = availableMonths.reduce(
        (a, b) => a.isAfter(b) ? a : b,
      );
      for (
        var cursor = currentMonth;
        cursor.isBefore(latestMonth);
        cursor = DateTime(cursor.year, cursor.month + 1)
      ) {
        availableMonths.add(cursor);
      }
      // 일정 데이터가 없어도 현재 달부터 12개월 뒤까지는 탐색할 수 있게
      // 합니다. 미래 날짜는 소식/관람 데이터가 없어도 선택 가능합니다.
      for (var i = 0; i <= 12; i++) {
        availableMonths.add(
          DateTime(currentMonth.year, currentMonth.month + i),
        );
      }
      final months = availableMonths.toList()..sort();
      final monthIndex = months.indexWhere(
        (m) => m.year == month.year && m.month == month.month,
      );
      void move(int delta) {
        final nextIndex = (monthIndex + delta).clamp(0, months.length - 1);
        final next = months[nextIndex];
        final attendedDays =
            grouped.keys
                .where(
                  (date) => date.year == next.year && date.month == next.month,
                )
                .where(
                  (date) => (grouped[date] ?? const []).any(
                    (item) => item['kind'] == null,
                  ),
                )
                .toList()
              ..sort();
        final targetDay = delta < 0 && attendedDays.isNotEmpty
            ? attendedDays.last.day
            : selected.day.clamp(1, DateTime(next.year, next.month + 1, 0).day);
        selection.value = DateTime(next.year, next.month, targetDay);
        SoundEffectService.instance.start(
          delta > 0 ? SoundEffect.pageFlip : SoundEffect.pageFlipBack,
          maxDuration: const Duration(milliseconds: 280),
        );
      }

      return GestureDetector(
        // 카드가 없는 하단 여백에서도 월 이동 제스처를 받습니다.
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity.abs() < 100) return;
          move(velocity < 0 ? 1 : -1);
        },
        child: LayoutBuilder(
          builder: (context, box) {
            // 배치는 달력 3 : 아래 2 그대로, 그리는 순서만 달력을 맨 위로 - Column이면
            // 뒤에 오는 아래 일정 영역이 위에 그려져, 찢겨 떨어지는 장이 그 밑으로 깔렸음
            final calendarHeight = (box.maxHeight - 20) * 3 / 5;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: calendarHeight,
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    children: [
                      const Divider(height: 20, color: _ink, thickness: .5),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: KeyedSubtree(
                            key: ValueKey(selected),
                            child: _dayDetail(selected, entries, grouped, now),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: calendarHeight,
                  child: _SheetTapes(
                    child: _MonthFlip(
                      monthIndex: month.year * 12 + month.month,
                      child: _SheetPaper(
                        child: Column(
                          children: [
                            Row(
                              children: [
                                IconButton(
                                  tooltip: '이전 달',
                                  onPressed: () => move(-1),
                                  icon: const Icon(
                                    Icons.chevron_left,
                                    color: _ink,
                                  ),
                                ),
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(10),
                                    onTap: () => _showMonthPicker(
                                      context,
                                      months,
                                      monthIndex,
                                      selected,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      child: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 280,
                                        ),
                                        transitionBuilder: (child, animation) =>
                                            FadeTransition(
                                              opacity: animation,
                                              child: child,
                                            ),
                                        child: Text(
                                          '${month.year}년 ${month.month}월',
                                          key: ValueKey(
                                            '${month.year}-${month.month}',
                                          ),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: _ink,
                                            fontSize: 22,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '다음 달',
                                  onPressed: () => move(1),
                                  icon: const Icon(
                                    Icons.chevron_right,
                                    color: _ink,
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                for (var weekday = 0; weekday < 7; weekday++)
                                  Expanded(
                                    child: Text(
                                      _weekdayNames[weekday],
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: weekday == 0
                                            ? const Color(0xFFD05252)
                                            : weekday == 6
                                            ? const Color(0xFF477DBA)
                                            : _ink,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            Expanded(
                              child: CustomPaint(
                                painter: _GridLinesPainter(rows: rows),
                                child: Column(
                                  children: [
                                    for (var row = 0; row < rows; row++)
                                      Expanded(
                                        child: Row(
                                          children: [
                                            for (var col = 0; col < 7; col++)
                                              Expanded(
                                                child: Builder(
                                                  builder: (context) {
                                                    final day =
                                                        row * 7 +
                                                        col -
                                                        offset +
                                                        1;
                                                    if (day < 1 || day > days) {
                                                      return const SizedBox.shrink();
                                                    }
                                                    final date = DateTime(
                                                      month.year,
                                                      month.month,
                                                      day,
                                                    );
                                                    final todayDate = DateTime(
                                                      now.year,
                                                      now.month,
                                                      now.day,
                                                    );
                                                    final items =
                                                        grouped[date] ??
                                                        const [];
                                                    final count = items.length;
                                                    final hasAttended = items
                                                        .any(
                                                          (item) =>
                                                              item['kind'] ==
                                                              null,
                                                        );
                                                    final selectable =
                                                        !date.isBefore(
                                                          todayDate,
                                                        ) ||
                                                        hasAttended;
                                                    return Semantics(
                                                      label:
                                                          '${month.month}월 $day일, 관람 $count회',
                                                      selected:
                                                          date == selected,
                                                      button: true,
                                                      child: InkWell(
                                                        key: ValueKey(
                                                          'calendar-${month.year}-${month.month}-$day',
                                                        ),
                                                        onTap: selectable
                                                            ? () {
                                                                selection
                                                                        .value =
                                                                    date;
                                                              }
                                                            : null,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              10,
                                                            ),
                                                        child: _DayCell(
                                                          day: day,
                                                          items: items,
                                                          active:
                                                              date == selected,
                                                          today:
                                                              date == todayDate,
                                                          dimmed: !selectable,
                                                          weekday: col,
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    },
  );

  /// 고른 날의 머리말 + 일정 목록. 비어 있으면 다음 일정 한 건만 한 줄로
  /// (세로/가로 모두 좁은 페이지라 정보를 많이 쌓지 않음).
  Widget _dayDetail(
    DateTime selected,
    List<Map<String, dynamic>> entries,
    Map<DateTime, List<Map<String, dynamic>>> grouped,
    DateTime now,
  ) {
    final attended = entries.where((e) => e['kind'] == null).length;
    final dayLabel = '${selected.month}월 ${selected.day}일';
    final header = attended > 0
        ? '$dayLabel · 관람 $attended회'
        : '$dayLabel (${_weekdayNames[selected.weekday % 7]})';
    final headerRow = Text(
      header,
      style: const TextStyle(
        color: _ink,
        fontSize: 15,
        fontWeight: FontWeight.w800,
      ),
    );

    final Widget body;
    if (entries.isNotEmpty) {
      body = ListView.separated(
        padding: const EdgeInsets.only(bottom: 8),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) => _entryCard(entries[i]),
      );
    } else {
      final today = DateTime(now.year, now.month, now.day);
      // 오늘이 아니라 고른 날 다음 일정 - 어느 날을 눌러도 같은 일정만 보이던 것.
      // 예매 오픈일은 달력의 "예매" 표시로 충분해서 다음 일정에선 공연만
      List<Map<String, dynamic>> shows(DateTime d) => (grouped[d] ?? const [])
          .where((e) => e['kind'] != 'ticketing')
          .toList();
      final upcoming =
          grouped.keys
              .where(
                (d) =>
                    d.isAfter(selected) &&
                    !d.isBefore(today) &&
                    shows(d).isNotEmpty,
              )
              .toList()
            ..sort();
      if (upcoming.isEmpty) {
        body = Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '비어 있는 날이에요',
            style: TextStyle(color: _ink.withValues(alpha: .55), fontSize: 13),
          ),
        );
      } else {
        final next = upcoming.first;
        final nextShows = shows(next);
        final first = nextShows.first;
        final title =
            (first['news'] as NewsModel?)?.concert ??
            '${first['concert_name'] ?? '공연'}';
        final more = nextShows.length - 1;
        // 고른 날 기준 남은 날수
        final dDay = next.difference(selected).inDays;
        body = Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => selection.value = next,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _diaryPaper.withValues(alpha: .7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Text(
                      dDay == 0 ? 'D-DAY' : 'D-$dDay',
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '다음 일정 · ${next.month}월 ${next.day}일',
                            style: TextStyle(
                              color: _ink.withValues(alpha: .6),
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            more > 0 ? '$title 외 $more건' : title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 18, color: _ink),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        headerRow,
        const SizedBox(height: 8),
        Expanded(child: body),
      ],
    );
  }

  /// 일정 한 건 카드(관람 기록 / 티케팅 / 공연 소식).
  Widget _entryCard(Map<String, dynamic> ticket) {
    final price = ticket['price'];
    final amount = price is num
        ? '${price.round()}'.replaceAllMapped(
            RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
            (m) => '${m[1]},',
          )
        : null;
    final seat = switch (ticket['seat']) {
      'standing' => '스탠딩',
      'seated' => '좌석',
      _ => null,
    };
    final newsItem = ticket['news'] as NewsModel?;
    if (newsItem != null) {
      final label = ticket['kind'] == 'ticketing' ? '[티케팅]' : '[공연]';
      return InkWell(
        onTap: () => onNewsTap?.call(newsItem),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: ticket['kind'] == 'ticketing' ? _diaryPaper : _paper,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  const Icon(Icons.chevron_right, size: 20, color: _ink),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                newsItem.concert,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (ticket['kind'] == 'ticketing' &&
                  newsItem.ticketingPhases?.isNotEmpty == true) ...[
                const SizedBox(height: 4),
                Text(
                  newsItem.ticketingPhases!.first.phase,
                  style: const TextStyle(color: _ink),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final poster = ticket['poster_url'] as String?;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: _paper,
        image: poster == null || poster.isEmpty
            ? null
            : DecorationImage(
                image: NetworkImage(poster),
                fit: BoxFit.cover,
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: .35),
                  BlendMode.darken,
                ),
              ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () => onTicketTap?.call(ticket),
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${ticket['concert_name'] ?? '공연'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: poster == null || poster.isEmpty
                          ? _ink
                          : Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: poster == null || poster.isEmpty ? _ink : Colors.white,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [if (amount != null) '$amount원', ?seat].join(' · '),
              style: TextStyle(
                color: poster == null || poster.isEmpty ? _ink : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMonthPicker(
    BuildContext context,
    List<DateTime> months,
    int selectedIndex,
    DateTime selected,
  ) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: _paper,
      builder: (context) {
        var pickedIndex = selectedIndex;
        return StatefulBuilder(
          builder: (context, setSheetState) => SizedBox(
            height: 320,
            child: Column(
              children: [
                Expanded(
                  child: ListWheelScrollView.useDelegate(
                    itemExtent: 48,
                    diameterRatio: 1.25,
                    physics: const FixedExtentScrollPhysics(),
                    controller: FixedExtentScrollController(
                      initialItem: selectedIndex,
                    ),
                    onSelectedItemChanged: (index) =>
                        setSheetState(() => pickedIndex = index),
                    childDelegate: ListWheelChildBuilderDelegate(
                      childCount: months.length,
                      builder: (context, index) => Center(
                        child: Text(
                          '${months[index].year}년 ${months[index].month}월',
                          style: const TextStyle(color: _ink, fontSize: 21),
                        ),
                      ),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, pickedIndex),
                  child: const Text('선택', style: TextStyle(color: _ink)),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) {
      final date = months[picked];
      selection.value = DateTime(
        date.year,
        date.month,
        selected.day.clamp(1, DateTime(date.year, date.month + 1, 0).day),
      );
    }
  }
}

/// 달력 한 칸. 포스터로만 표시 - 관람한 날은 기울여 붙인 포스터 스티커, 다가오는
/// 공연은 흐린 미니 포스터(연필로 적어둔 예정), 예매 오픈일은 날짜 아래 작은 "예매".
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.items,
    required this.active,
    required this.today,
    required this.dimmed,
    required this.weekday,
  });

  final int day;
  final List<Map<String, dynamic>> items;
  final bool active, today, dimmed;
  final int weekday;

  static Widget _ticketIcon() => const Center(
    child: Icon(Icons.confirmation_number_outlined, color: _ink, size: 18),
  );

  @override
  Widget build(BuildContext context) {
    final attended = items.where((item) => item['kind'] == null).toList();
    String? firstUrl(Iterable<String?> urls) => urls.firstWhere(
      (url) => url != null && url.isNotEmpty,
      orElse: () => null,
    );
    final poster = firstUrl(attended.map((t) => t['poster_url'] as String?));
    final upcomingPoster = firstUrl(
      items
          .where((item) => item['kind'] == 'concert')
          .map((item) => (item['news'] as NewsModel?)?.imageUrl),
    );
    final ticketing = items.any((item) => item['kind'] == 'ticketing');
    final dayColor = weekday == 0
        ? const Color(0xFFD05252)
        : weekday == 6
        ? const Color(0xFF477DBA)
        : _ink;
    // 칸마다 기울기를 조금씩 달리해 손으로 붙인 느낌
    final tilt = (day % 3 - 1) * 0.06;

    final Widget body;
    if (attended.isNotEmpty) {
      body = Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.all(3),
            child: Transform.rotate(
              angle: tilt,
              child: Container(
                decoration: BoxDecoration(
                  color: _diaryPaper,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .22),
                      blurRadius: 4,
                      offset: const Offset(1, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: poster == null
                      ? _ticketIcon()
                      : AppNetworkImage(
                          poster,
                          memCacheWidth: 160,
                          errorBuilder: (_) => _ticketIcon(),
                        ),
                ),
              ),
            ),
          ),
          // 스티커 위 날짜는 왼쪽 위 작은 딱지로
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: _ink,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                attended.length > 1 ? '$day ×${attended.length}' : '$day',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      body = Stack(
        fit: StackFit.expand,
        children: [
          // 다가오는 공연은 칸 전체에 흐린 포스터(연필로 적어둔 예정) - 가로모드처럼
          // 칸이 납작해도 보이도록 미니 포스터 대신 배경으로 깖
          if (upcomingPoster != null)
            Padding(
              padding: const EdgeInsets.all(3),
              child: Opacity(
                opacity: .38,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: AppNetworkImage(
                    upcomingPoster,
                    memCacheWidth: 160,
                    errorBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          // 플래너처럼 날짜는 왼쪽 위에 작게 - 칸 가운데 큰 숫자가 어색했음.
          // 관람 스티커 칸의 날짜 딱지와 같은 자리
          Positioned(
            left: 3,
            top: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              decoration: upcomingPoster == null
                  ? null
                  : BoxDecoration(
                      color: const Color(0xFFF8F3E6).withValues(alpha: .85),
                      borderRadius: BorderRadius.circular(4),
                    ),
              child: Text(
                '$day',
                style: TextStyle(
                  color: dimmed ? dayColor.withValues(alpha: .45) : dayColor,
                  fontSize: 13,
                  fontWeight: today || upcomingPoster != null
                      ? FontWeight.w900
                      : FontWeight.w600,
                  decoration: today ? TextDecoration.underline : null,
                  decorationColor: _ink,
                  decorationThickness: 2,
                ),
              ),
            ),
          ),
          if (ticketing)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 3,
              child: Text(
                '예매',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _ink,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.all(2),
      child: Stack(
        fit: StackFit.expand,
        children: [
          body,
          if (active)
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _ink, width: 2),
                  color: attended.isEmpty ? _ink.withValues(alpha: .08) : null,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 크라프트지 페이지 위에 붙인 크림색 달력 종이 - 숫자/스티커가 단색 배경에
/// 떠 보이던 것. 테이프([_SheetTapes])와 나눠서, 월 넘김 때 종이만 넘어가고
/// 테이프는 제자리에 남게 함.
class _SheetPaper extends StatelessWidget {
  const _SheetPaper({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
    decoration: BoxDecoration(
      color: const Color(0xFFF8F3E6),
      borderRadius: BorderRadius.circular(3),
      boxShadow: [
        BoxShadow(
          color: _ink.withValues(alpha: .22),
          blurRadius: 6,
          offset: const Offset(1, 3),
        ),
      ],
    ),
    child: child,
  );
}

/// 달력 종이 윗모서리 두 곳의 마스킹테이프.
class _SheetTapes extends StatelessWidget {
  const _SheetTapes({required this.child});
  final Widget child;

  static Widget _tape(double angle) =>
      MaskingTape(width: 54, height: 16, angle: angle);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: child),
        Positioned(top: -9, left: 18, child: _tape(-.12)),
        Positioned(top: -9, right: 18, child: _tape(.1)),
      ],
    ),
  );
}

/// 달력 칸을 구분하는 옅은 인쇄 선(플래너 느낌).
class _GridLinesPainter extends CustomPainter {
  const _GridLinesPainter({required this.rows});
  final int rows;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _ink.withValues(alpha: .13)
      ..strokeWidth = .8;
    for (var r = 0; r <= rows; r++) {
      final y = size.height * r / rows;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (var c = 1; c < 7; c++) {
      final x = size.width * c / 7;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridLinesPainter oldDelegate) =>
      oldDelegate.rows != rows;
}

/// 월이 바뀌면 달력 장을 넘기는 연출. 다음 달: 지금 장이 테이프 바로 아래에서
/// 찢겨 한쪽 모서리부터 기울며 아래로 떨어짐(테이프 밑엔 찢긴 띠가 잠깐 남음).
/// 이전 달: 이전 장이 위에서 내려와 테이프 밑에 붙음. (윗변 축 3D 회전은 내용이
/// 찌그러져 카드 뒤집기처럼 보여 바꿈)
class _MonthFlip extends StatefulWidget {
  const _MonthFlip({required this.monthIndex, required this.child});
  final int monthIndex;
  final Widget child;
  @override
  State<_MonthFlip> createState() => _MonthFlipState();
}

class _MonthFlipState extends State<_MonthFlip>
    with SingleTickerProviderStateMixin {
  // initState에서 만듦 - late 지연 생성이면 월을 한 번도 안 넘긴 채 dispose될 때
  // 처음 만들어지면서 비활성 위젯의 조상(TickerMode)을 찾다 오류가 남
  late final AnimationController _controller;
  Widget? _old;
  bool _forward = true;

  /// 테이프 바로 아래 찢는 선 위치(종이 윗변에서)
  static const _tearY = 14.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
  }

  @override
  void didUpdateWidget(covariant _MonthFlip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.monthIndex != widget.monthIndex) {
      // 빠르게 연달아 넘기면 진행 중이던 연출은 버리고 바로 다음 것으로
      _old = oldWidget.child;
      _forward = widget.monthIndex > oldWidget.monthIndex;
      _controller.forward(from: 0).whenComplete(() {
        if (mounted) setState(() => _old = null);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _torn(Widget old, double v, Size size) {
    final seed = widget.monthIndex;
    // 찢어지는 순간 살짝 버티다가 떨어지도록 앞 15%는 거의 안 움직임
    final fall = Curves.easeIn.transform(((v - .12) / .88).clamp(0.0, 1.0));
    final stripFade = (1 - v * 1.6).clamp(0.0, 1.0);
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 테이프 밑에 남는 찢긴 띠
          Opacity(
            opacity: stripFade,
            child: ClipPath(
              clipper: _TearClipper(seed: seed, tearY: _tearY, top: true),
              child: old,
            ),
          ),
          // 찢겨 떨어지는 본장 - 오른쪽 위 모서리가 먼저 내려가며 기울어짐
          Opacity(
            // 떨어지는 동안은 불투명한 종이로 - 일찍 투명해지면 다음 달이 비쳐 유령처럼 보였음
            opacity: (1 - (fall - .65) / .35).clamp(0.0, 1.0),
            child: Transform(
              alignment: Alignment.topLeft,
              transform: Matrix4.identity()
                ..translateByDouble(0, fall * size.height * .55, 0, 1)
                ..rotateZ(fall * .22),
              child: ClipPath(
                clipper: _TearClipper(seed: seed, tearY: _tearY, top: false),
                child: old,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _drop(Widget incoming, double v, Size size) {
    final t = Curves.easeOutBack.transform(v);
    return IgnorePointer(
      ignoring: v < 1,
      child: Opacity(
        opacity: (v * 7).clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, -(1 - t) * size.height * .18),
          child: incoming,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final old = _old;
    if (old == null) return widget.child;
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final v = _controller.value;
            return Stack(
              fit: StackFit.expand,
              children: _forward
                  ? [widget.child, _torn(old, v, size)]
                  : [IgnorePointer(child: old), _drop(widget.child, v, size)],
            );
          },
        );
      },
    );
  }
}

/// 테이프 아래를 가로지르는 들쭉날쭉한 찢김 선으로 종이를 위(띠)/아래(본장)로 자름.
class _TearClipper extends CustomClipper<Path> {
  const _TearClipper({
    required this.seed,
    required this.tearY,
    required this.top,
  });
  final int seed;
  final double tearY;
  final bool top;

  List<Offset> _edge(Size size) {
    final rnd = math.Random(seed);
    final points = <Offset>[];
    for (double x = 0; x <= size.width; x += 7) {
      points.add(Offset(x, tearY + (rnd.nextDouble() - .5) * 6));
    }
    points.add(Offset(size.width, tearY + (rnd.nextDouble() - .5) * 6));
    return points;
  }

  @override
  Path getClip(Size size) {
    final edge = _edge(size);
    final path = Path();
    if (top) {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      for (final p in edge.reversed) {
        path.lineTo(p.dx, p.dy);
      }
    } else {
      path.moveTo(edge.first.dx, edge.first.dy);
      for (final p in edge.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
    }
    return path..close();
  }

  @override
  bool shouldReclip(covariant _TearClipper oldClipper) =>
      oldClipper.seed != seed ||
      oldClipper.tearY != tearY ||
      oldClipper.top != top;
}
