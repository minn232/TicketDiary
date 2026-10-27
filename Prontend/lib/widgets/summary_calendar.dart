import 'dart:async';

import 'package:flutter/material.dart';
import '../models/news_model.dart';
import '../services/sound_effect_service.dart';

const _ink = Color(0xFF5C4033);
const _paper = Color(0xFFE5D3B9);
const _diaryPaper = Color(0xFFF4F1E1);

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
          SoundEffect.pageFlip,
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
        child: Column(
          children: [
            Expanded(
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: '이전 달',
                        onPressed: () => move(-1),
                        icon: const Icon(Icons.chevron_left, color: _ink),
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
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 280),
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  ),
                              child: Text(
                                '${month.year}년 ${month.month}월',
                                key: ValueKey('${month.year}-${month.month}'),
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
                        icon: const Icon(Icons.chevron_right, color: _ink),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      for (var weekday = 0; weekday < 7; weekday++)
                        Expanded(
                          child: Text(
                            ['일', '월', '화', '수', '목', '금', '토'][weekday],
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
                                        final day = row * 7 + col - offset + 1;
                                        if (day < 1 || day > days) {
                                          return const SizedBox.shrink();
                                        }
                                        final date = DateTime(
                                          month.year,
                                          month.month,
                                          day,
                                        );
                                        final active = date == selected;
                                        final count =
                                            grouped[date]?.length ?? 0;
                                        final hasAttended =
                                            (grouped[date] ?? const []).any(
                                              (item) => item['kind'] == null,
                                            );
                                        final isPast = date.isBefore(
                                          DateTime(
                                            now.year,
                                            now.month,
                                            now.day,
                                          ),
                                        );
                                        final selectable =
                                            !isPast || hasAttended;
                                        final today =
                                            date ==
                                            DateTime(
                                              now.year,
                                              now.month,
                                              now.day,
                                            );
                                        return Semantics(
                                          label:
                                              '${month.month}월 $day일, 관람 $count회',
                                          selected: active,
                                          button: true,
                                          child: InkWell(
                                            key: ValueKey(
                                              'calendar-${month.year}-${month.month}-$day',
                                            ),
                                            onTap: selectable
                                                ? () {
                                                    selection.value = date;
                                                  }
                                                : null,
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            child: Container(
                                              margin: const EdgeInsets.all(2),
                                              decoration: BoxDecoration(
                                                color: active ? _ink : null,
                                                border: today
                                                    ? Border.all(color: _ink)
                                                    : null,
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                              ),
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      '$day',
                                                      style: TextStyle(
                                                        color: active
                                                            ? _paper
                                                            : col == 0
                                                            ? const Color(
                                                                0xFFD05252,
                                                              )
                                                            : col == 6
                                                            ? const Color(
                                                                0xFF477DBA,
                                                              )
                                                            : _ink,
                                                        fontSize: 16,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 3),
                                                    SizedBox(
                                                      height: 6,
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          for (final item
                                                              in grouped[date] ??
                                                                  const <
                                                                    Map<
                                                                      String,
                                                                      dynamic
                                                                    >
                                                                  >[])
                                                            Container(
                                                              width: 5,
                                                              height: 5,
                                                              margin:
                                                                  const EdgeInsets.symmetric(
                                                                    horizontal:
                                                                        1,
                                                                  ),
                                                              decoration: BoxDecoration(
                                                                shape: BoxShape
                                                                    .circle,
                                                                border:
                                                                    Border.all(
                                                                      color:
                                                                          _ink,
                                                                      width: .5,
                                                                    ),
                                                                color:
                                                                    item['kind'] ==
                                                                        'ticketing'
                                                                    ? _diaryPaper
                                                                    : active
                                                                    ? _paper
                                                                    : _ink,
                                                              ),
                                                            ),
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
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 20, color: _ink, thickness: .5),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: entries.isEmpty
                        ? const Center(
                            child: Text(
                              '선택한 기간에 해당 날짜의 관람 기록이 없어요',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: _ink),
                            ),
                          )
                        : ListView.separated(
                            key: ValueKey(selected),
                            padding: const EdgeInsets.only(bottom: 8),
                            itemCount: entries.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, i) {
                              final ticket = entries[i];
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
                                final label = ticket['kind'] == 'ticketing'
                                    ? '[티케팅]'
                                    : '[공연]';
                                return InkWell(
                                  onTap: () => onNewsTap?.call(newsItem),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: ticket['kind'] == 'ticketing'
                                          ? _diaryPaper
                                          : _paper,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                            const Icon(
                                              Icons.touch_app_outlined,
                                              size: 19,
                                              color: _ink,
                                            ),
                                            const Icon(
                                              Icons.chevron_right,
                                              size: 20,
                                              color: _ink,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          newsItem.concert,
                                          style: const TextStyle(
                                            color: _ink,
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        if (ticket['kind'] == 'ticketing') ...[
                                          if (newsItem
                                                  .ticketingPhases
                                                  ?.isNotEmpty ==
                                              true)
                                            Text(
                                              newsItem
                                                  .ticketingPhases!
                                                  .first
                                                  .phase,
                                              style: const TextStyle(
                                                color: _ink,
                                              ),
                                            ),
                                        ] else ...[
                                          Builder(
                                            builder: (context) {
                                              final day = ticket['day'] as int?;
                                              return Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  if (day != null && day > 0)
                                                    Text(
                                                      '$day일차 공연',
                                                      style: const TextStyle(
                                                        color: _ink,
                                                      ),
                                                    ),
                                                ],
                                              );
                                            },
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              }
                              final poster = ticket['poster_url'] as String?;
                              return Container(
                                padding: const EdgeInsets.all(12),
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '${ticket['concert_name'] ?? '공연'}',
                                              style: TextStyle(
                                                color:
                                                    poster == null ||
                                                        poster.isEmpty
                                                    ? _ink
                                                    : Colors.white,
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          Icon(
                                            Icons.touch_app_outlined,
                                            size: 19,
                                            color:
                                                poster == null || poster.isEmpty
                                                ? _ink
                                                : Colors.white,
                                          ),
                                          Icon(
                                            Icons.chevron_right,
                                            size: 20,
                                            color:
                                                poster == null || poster.isEmpty
                                                ? _ink
                                                : Colors.white,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        [
                                          if (amount != null) '$amount원',
                                          ?seat,
                                        ].join(' · '),
                                        style: TextStyle(
                                          color:
                                              poster == null || poster.isEmpty
                                              ? _ink
                                              : Colors.white,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
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
      );
    },
  );

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
