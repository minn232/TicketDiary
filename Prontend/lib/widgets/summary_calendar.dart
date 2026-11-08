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

class SummaryCalendar extends StatefulWidget {
  const SummaryCalendar({
    super.key,
    required this.tickets,
    required this.selection,
    this.news = const [],
    this.onNewsTap,
    this.onTicketTap,
    this.todayRequest,
  });
  final List<Map<String, dynamic>> tickets;
  final ValueNotifier<DateTime> selection;
  final List<NewsModel> news;
  final ValueChanged<NewsModel>? onNewsTap;
  final ValueChanged<Map<String, dynamic>>? onTicketTap;

  /// [백엔드 수정] 값이 바뀔 때마다 오늘로 돌아감(결산 화면의 오늘 날짜 버튼)
  final Listenable? todayRequest;

  @override
  State<SummaryCalendar> createState() => _SummaryCalendarState();
}

/// 월 달력 + 연 모아보기. 월 제목을 누르면 달 종이가 작아지며 1년 종이의 제 칸으로
/// 들어가고(줌아웃), 연 화면에서 달 칸을 누르면 그 칸이 커지며 월 달력이 됨(줌인).
class _SummaryCalendarState extends State<SummaryCalendar>
    with SingleTickerProviderStateMixin {
  ValueNotifier<DateTime> get selection => widget.selection;
  List<Map<String, dynamic>> get tickets => widget.tickets;
  List<NewsModel> get news => widget.news;
  ValueChanged<NewsModel>? get onNewsTap => widget.onNewsTap;
  ValueChanged<Map<String, dynamic>>? get onTicketTap => widget.onTicketTap;

  /// 0 = 월 달력, 1 = 연 모아보기
  late final AnimationController _zoom;

  /// 연 화면에서 보고 있는 해
  int _year = DateTime.now().year;

  /// 연 화면에서 달을 골라 돌아올 때 올림 - 월 넘김(찢김) 연출 없이 새 달 종이로 시작
  int _sheetEpoch = 0;

  @override
  void initState() {
    super.initState();
    _zoom = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    widget.todayRequest?.addListener(_goToday);
  }

  @override
  void didUpdateWidget(covariant SummaryCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.todayRequest != widget.todayRequest) {
      oldWidget.todayRequest?.removeListener(_goToday);
      widget.todayRequest?.addListener(_goToday);
    }
  }

  /// 연 화면이면 올해 종이에서 이번 달 칸으로 줌인, 월 화면이면 달력 장을 넘겨 오늘로
  /// (같은 달이면 고른 날만 오늘로 옮김)
  void _goToday() {
    if (_zoom.isAnimating) return;
    final today = DateUtils.dateOnly(DateTime.now());
    if (_zoom.value > 0) {
      setState(() => _year = today.year);
      _zoomIn(today);
      return;
    }
    final current = selection.value;
    if (DateUtils.isSameDay(current, today)) return;
    selection.value = today;
    if (current.year != today.year || current.month != today.month) {
      SoundEffectService.instance.start(
        today.isAfter(current)
            ? SoundEffect.pageFlip
            : SoundEffect.pageFlipBack,
        maxDuration: const Duration(milliseconds: 280),
      );
    }
  }

  @override
  void dispose() {
    widget.todayRequest?.removeListener(_goToday);
    _zoom.dispose();
    super.dispose();
  }

  void _zoomOut(DateTime month) {
    if (_zoom.isAnimating) return;
    setState(() => _year = month.year);
    _zoom.forward();
    SoundEffectService.instance.start(
      SoundEffect.pageFlipBack,
      maxDuration: const Duration(milliseconds: 280),
    );
  }

  void _zoomIn(DateTime date) {
    if (_zoom.isAnimating) return;
    setState(() => _sheetEpoch++);
    selection.value = date;
    _zoom.reverse();
    SoundEffectService.instance.start(
      SoundEffect.pageFlip,
      maxDuration: const Duration(milliseconds: 280),
    );
  }

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
        // [백엔드 수정] 첫/마지막 달에서 더 넘기면 달도 소리도 그대로.
        if (nextIndex == monthIndex) return;
        final next = months[nextIndex];
        // [백엔드 수정] 앞뒤 모두 일정 있는 날로 - 뒤로 가면 그 달 마지막, 앞으로 가면 첫 일정.
        // 공연(본 공연·내 티켓·소식 공연)이 있는 날을 먼저 보고, 없으면 예매일.
        final monthDays =
            grouped.keys
                .where(
                  (date) => date.year == next.year && date.month == next.month,
                )
                .toList()
              ..sort();
        final showDays = monthDays
            .where(
              (date) => (grouped[date] ?? const []).any(
                (item) => item['kind'] != 'ticketing',
              ),
            )
            .toList();
        final eventDays = showDays.isNotEmpty ? showDays : monthDays;
        // 오늘이 든 달은 일정과 상관없이 오늘로
        final isThisMonth = next.year == now.year && next.month == now.month;
        final targetDay = isThisMonth
            ? now.day
            : eventDays.isNotEmpty
            ? (delta < 0 ? eventDays.last : eventDays.first).day
            : selected.day.clamp(1, DateTime(next.year, next.month + 1, 0).day);
        selection.value = DateTime(next.year, next.month, targetDay);
        SoundEffectService.instance.start(
          delta > 0 ? SoundEffect.pageFlip : SoundEffect.pageFlipBack,
          maxDuration: const Duration(milliseconds: 280),
        );
      }

      // 연 모아보기: 월 달력으로 넘길 수 있는 달의 해 전부(기록 있는 해 + 올해~12개월 뒤).
      // 전엔 기록 있는 해 + 올해만이라 내년 달에서 축소하면 목록에 없어 이동이 막혔음
      final years = {for (final m in months) m.year}.toList()..sort();
      void moveYear(int delta) {
        final index = years.indexOf(_year);
        final next = index + delta;
        if (index < 0 || next < 0 || next >= years.length) return;
        setState(() => _year = years[next]);
        SoundEffectService.instance.start(
          delta > 0 ? SoundEffect.pageFlip : SoundEffect.pageFlipBack,
          maxDuration: const Duration(milliseconds: 280),
        );
      }

      /// 연 화면에서 달 칸을 누르면 그 달의 첫 관람일(없으면 이번 달은 오늘, 아니면 1일)로
      void openMonth(DateTime target) {
        final attendedDays =
            grouped.keys
                .where(
                  (date) =>
                      date.year == target.year &&
                      date.month == target.month &&
                      (grouped[date] ?? const []).any(
                        (item) => item['kind'] == null,
                      ),
                )
                .toList()
              ..sort();
        final day = attendedDays.isNotEmpty
            ? attendedDays.first.day
            : target.year == now.year && target.month == now.month
            ? now.day
            : 1;
        _zoomIn(DateTime(target.year, target.month, day));
      }

      return GestureDetector(
        // 카드가 없는 하단 여백에서도 월 이동 제스처를 받습니다.
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (details) {
          if (_zoom.isAnimating) return;
          final velocity = details.primaryVelocity ?? 0;
          if (velocity.abs() < 100) return;
          if (_zoom.value == 1) {
            moveYear(velocity < 0 ? 1 : -1);
          } else {
            move(velocity < 0 ? 1 : -1);
          }
        },
        child: LayoutBuilder(
          builder: (context, box) {
            // 배치는 달력 3 : 아래 2 그대로, 그리는 순서만 달력을 맨 위로 - Column이면
            // 뒤에 오는 아래 일정 영역이 위에 그려져, 찢겨 떨어지는 장이 그 밑으로 깔렸음
            final calendarHeight = (box.maxHeight - 20) * 3 / 5;
            final geometry = _YearGeometry(box.biggest);
            final detail = Column(
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
            );
            final yearView = _yearSheet(
              geometry,
              years,
              months,
              now,
              moveYear,
              openMonth,
            );
            final sheet = _SheetTapes(
              child: _MonthFlip(
                key: ValueKey(_sheetEpoch),
                monthIndex: month.year * 12 + month.month,
                child: _SheetPaper(
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
                              // 연 모아보기에서 이동할 달을 선택합니다.
                              onTap: () => _zoomOut(month),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 280),
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
                            icon: const Icon(Icons.chevron_right, color: _ink),
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
                          painter: _GridLinesPainter(rows: rows, cols: 7),
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
                                                  row * 7 + col - offset + 1;
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
                                                  grouped[date] ?? const [];
                                              final count = items.length;
                                              final hasAttended = items.any(
                                                (item) => item['kind'] == null,
                                              );
                                              final selectable =
                                                  !date.isBefore(todayDate) ||
                                                  hasAttended;
                                              return Semantics(
                                                label:
                                                    '${month.month}월 $day일, 관람 $count회',
                                                selected: date == selected,
                                                button: true,
                                                child: InkWell(
                                                  key: ValueKey(
                                                    'calendar-${month.year}-${month.month}-$day',
                                                  ),
                                                  onTap: selectable
                                                      ? () {
                                                          selection.value =
                                                              date;
                                                        }
                                                      : null,
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                  child: _DayCell(
                                                    day: day,
                                                    items: items,
                                                    active: date == selected,
                                                    today: date == todayDate,
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
            );
            return _zoomStack(
              box.biggest,
              calendarHeight,
              geometry.cell(month.month),
              detail,
              sheet,
              yearView,
            );
          },
        ),
      );
    },
  );

  /// 월 달력(종이 + 아래 일정)과 연 모아보기를 겹쳐 줌으로 오감. 연 종이는 고른 달
  /// 칸이 달 종이 자리를 덮도록 크게 키운 상태에서 제 크기로 줄어들고, 달 종이는 같은
  /// 비율로 줄어들며 그 칸 안으로 들어가 흐려짐 - 두 장이 한 장처럼 함께 움직임.
  Widget _zoomStack(
    Size size,
    double calendarHeight,
    Rect cell,
    Widget detail,
    Widget sheet,
    Widget yearView,
  ) {
    final sheetRect = Rect.fromLTWH(0, 0, size.width, calendarHeight);
    // 달 종이가 칸 안에 다 들어가는 배율(가로/세로 중 더 많이 줄여야 하는 쪽)
    final s0 = math.max(
      sheetRect.width / cell.width,
      sheetRect.height / cell.height,
    );
    return AnimatedBuilder(
      animation: _zoom,
      builder: (context, _) {
        final v = _zoom.value;
        final t = Curves.easeInOutCubic.transform(v);
        final k = s0 + (1 - s0) * t;
        final center = Offset.lerp(sheetRect.center, cell.center, t)!;
        // origin 점이 center로 가도록 scale배 확대/축소
        Matrix4 scaleAround(Offset origin, double scale) =>
            Matrix4.diagonal3Values(scale, scale, 1)..setTranslationRaw(
              center.dx - origin.dx * scale,
              center.dy - origin.dy * scale,
              0,
            );
        final settled = !_zoom.isAnimating;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (v < 1)
              Positioned(
                key: const ValueKey('calendar-detail'),
                top: calendarHeight,
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: v > 0,
                  child: Opacity(
                    opacity: (1 - t * 3.5).clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(0, t * 40),
                      child: detail,
                    ),
                  ),
                ),
              ),
            if (v > 0)
              Positioned.fill(
                key: const ValueKey('calendar-year'),
                child: IgnorePointer(
                  ignoring: !(settled && v == 1),
                  child: Opacity(
                    // 달 종이가 아직 클 때 크게 키운 이웃 칸이 아래 일정 위로
                    // 흐리게 비쳐 지저분했음 - 어느 정도 줄어든 뒤부터 보이게
                    opacity: ((t - .25) / .4).clamp(0.0, 1.0),
                    // 크게 키운 연 종이가 결산 탭 밖으로 넘치지 않게 잘라냄
                    child: ClipRect(
                      clipBehavior: settled ? Clip.none : Clip.hardEdge,
                      child: Transform(
                        transform: scaleAround(cell.center, k),
                        child: yearView,
                      ),
                    ),
                  ),
                ),
              ),
            if (v < 1)
              Positioned(
                key: const ValueKey('calendar-month'),
                top: 0,
                left: 0,
                right: 0,
                height: calendarHeight,
                child: IgnorePointer(
                  ignoring: v > 0,
                  child: Opacity(
                    opacity: (1 - (t - .55) / .4).clamp(0.0, 1.0),
                    child: Transform(
                      transform: scaleAround(sheetRect.center, k / s0),
                      child: sheet,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 연 모아보기 종이 - 달 종이와 같은 크림색 종이·테이프에 12달 칸, 칸마다 그 달에
  /// 본 공연 포스터를 겹쳐 붙임. 칸 위치는 [_YearGeometry]와 똑같이 맞춰야 줌이 맞음.
  Widget _yearSheet(
    _YearGeometry geometry,
    List<int> years,
    List<DateTime> months,
    DateTime now,
    void Function(int delta) moveYear,
    void Function(DateTime month) openMonth,
  ) {
    final year = _year;
    final byMonth = <int, List<Map<String, dynamic>>>{};
    for (final ticket in tickets) {
      final date = DateTime.tryParse('${ticket['date']}');
      // [백엔드 수정] 아직 안 간 내 티켓(myTicket)은 연 모아보기에 안 붙임(본 공연만).
      if (date == null || date.year != year || ticket['kind'] != null) continue;
      (byMonth[date.month] ??= []).add(ticket);
    }
    for (final list in byMonth.values) {
      list.sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
    }
    final total = byMonth.values.fold<int>(0, (sum, l) => sum + l.length);
    int? busiest;
    for (final entry in byMonth.entries) {
      if (busiest == null || entry.value.length > byMonth[busiest]!.length) {
        busiest = entry.key;
      }
    }
    final yearIndex = years.indexOf(year);
    // 월 달력에서 넘겨 갈 수 있는 달만 누를 수 있게(기록 없는 지난 달은 흐리게)
    final openable = {for (final m in months) m.year * 12 + m.month};

    Widget arrow(IconData icon, String tooltip, int delta) {
      final next = yearIndex + delta;
      final enabled = yearIndex >= 0 && next >= 0 && next < years.length;
      return IconButton(
        tooltip: tooltip,
        onPressed: enabled ? () => moveYear(delta) : null,
        icon: Icon(icon, color: enabled ? _ink : _ink.withValues(alpha: .25)),
      );
    }

    return _SheetTapes(
      child: _MonthFlip(
        monthIndex: year,
        child: _SheetPaper(
          child: Column(
            children: [
              SizedBox(
                height: _YearGeometry.header,
                child: Row(
                  children: [
                    arrow(Icons.chevron_left, '이전 해', -1),
                    Expanded(
                      child: Text(
                        '$year년',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    arrow(Icons.chevron_right, '다음 해', 1),
                  ],
                ),
              ),
              Expanded(
                child: CustomPaint(
                  painter: _GridLinesPainter(
                    rows: geometry.rows,
                    cols: geometry.cols,
                  ),
                  child: Column(
                    children: [
                      for (var row = 0; row < geometry.rows; row++)
                        Expanded(
                          child: Row(
                            children: [
                              for (var col = 0; col < geometry.cols; col++)
                                Expanded(
                                  child: Builder(
                                    builder: (context) {
                                      final m = row * geometry.cols + col + 1;
                                      final shows = byMonth[m] ?? const [];
                                      final enabled = openable.contains(
                                        year * 12 + m,
                                      );
                                      return Semantics(
                                        label:
                                            '$year년 $m월, 관람 ${shows.length}회',
                                        button: enabled,
                                        child: InkWell(
                                          key: ValueKey(
                                            'calendar-year-$year-$m',
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          onTap: enabled
                                              ? () =>
                                                    openMonth(DateTime(year, m))
                                              : null,
                                          child: _MonthCell(
                                            month: m,
                                            posters: [
                                              for (final t in shows)
                                                t['poster_url'] as String?,
                                            ],
                                            current:
                                                year == now.year &&
                                                m == now.month,
                                            dimmed: !enabled,
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
              SizedBox(
                height: _YearGeometry.footer,
                child: Center(
                  child: Text(
                    total == 0
                        ? '$year년엔 아직 관람 기록이 없어요'
                        : '$year년 관람 $total회 · 가장 많이 간 달 $busiest월',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _ink.withValues(alpha: .7),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
    // [백엔드 수정] 아직 안 간 내 티켓도 가는 게 확정이라 본 공연처럼 포스터 스티커로
    // (흐린 포스터는 소식 공연과 겹쳐 보였음).
    final attended = items
        .where((item) => item['kind'] == null || item['kind'] == 'myTicket')
        .toList();
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
  const _GridLinesPainter({required this.rows, required this.cols});
  final int rows, cols;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _ink.withValues(alpha: .13)
      ..strokeWidth = .8;
    for (var r = 0; r <= rows; r++) {
      final y = size.height * r / rows;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (var c = 1; c < cols; c++) {
      final x = size.width * c / cols;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridLinesPainter oldDelegate) =>
      oldDelegate.rows != rows || oldDelegate.cols != cols;
}

/// 월이 바뀌면 달력 장을 넘기는 연출. 다음 달: 지금 장이 테이프 바로 아래에서
/// 찢겨 한쪽 모서리부터 기울며 아래로 떨어짐(테이프 밑엔 찢긴 띠가 잠깐 남음).
/// 이전 달: 찢김을 거꾸로 감음 - 떨어졌던 이전 장이 아래에서 기운 채 올라와
/// 찢긴 선에 맞춰 다시 붙음. (윗변 축 3D 회전은 내용이 찌그러져 카드 뒤집기처럼
/// 보여 바꿈. 위에서 내려와 붙던 이전 방식은 떨어진 방향과 반대라 덜 직관적이었음)
class _MonthFlip extends StatefulWidget {
  const _MonthFlip({super.key, required this.monthIndex, required this.child});
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

  /// 찢김 선 모양 - 같은 두 달 사이는 앞뒤 어느 쪽으로 넘겨도 같은 선이 되도록
  /// 둘 중 큰 달 번호로 정함
  int _seed = 0;

  /// 테이프 바로 아래 찢는 선 위치(종이 윗변에서)
  static const _tearY = 14.0;

  /// [백엔드 수정] 이전 달로 연타할 때 올라오는 연출을 시작할 지점(0~1).
  static const _rapidRewindFrom = 0.7;

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
      final rapid = _controller.isAnimating;
      _old = oldWidget.child;
      _forward = widget.monthIndex > oldWidget.monthIndex;
      _seed = math.max(widget.monthIndex, oldWidget.monthIndex);
      // [백엔드 수정] 이전 달은 아래에서 올라와 붙어야 보여서, 연타 때 처음부터 올리면 미래 쪽보다
      // 느리게 느껴짐 - 넘기는 중에 또 누르면 거의 다 올라온 지점부터 시작.
      final from = !_forward && rapid ? _rapidRewindFrom : 0.0;
      _controller.forward(from: from).whenComplete(() {
        if (mounted) setState(() => _old = null);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// [v]가 0→1이면 찢겨 떨어지고, 1→0으로 주면 거꾸로 올라와 다시 붙음(이전 달).
  /// [settle]은 다시 붙는 순간 본장이 아래로 살짝 눌렸다 돌아오는 양(px).
  /// [fadeFrom]: 떨어진 정도가 이 값을 넘으면 투명해지기 시작 - 거꾸로 감을 땐 크게
  /// 줘서 올라오기 시작하자마자 불투명하게(일찍 비치면 밑장이 보여 유령처럼 보임)
  Widget _torn(
    Widget old,
    double v,
    Size size, {
    double settle = 0,
    double fadeFrom = .65,
  }) {
    final seed = _seed;
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
            opacity: (1 - (fall - fadeFrom) / (1 - fadeFrom)).clamp(0.0, 1.0),
            child: Transform(
              alignment: Alignment.topLeft,
              transform: Matrix4.identity()
                ..translateByDouble(0, fall * size.height * .55 + settle, 0, 1)
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
            if (_forward) {
              return Stack(
                fit: StackFit.expand,
                children: [widget.child, _torn(old, v, size)],
              );
            }
            // 거꾸로 감으면 마지막 12%는 이미 제자리 - 그 구간에 붙는 순간 살짝 눌림
            final land = ((v - .88) / .12).clamp(0.0, 1.0);
            return Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(child: old),
                // [백엔드 수정] 올라오는 종이는 터치를 막아 연출이 끝날 때까지 버튼이 안 눌려 연타가 느렸음 -
                // 안 보이는 이번 달을 제자리에 깔아 바로 누를 수 있게 함(미래 쪽은 새 달이 밑에 깔려 있어 원래 됨).
                Opacity(opacity: 0, child: widget.child),
                _torn(
                  widget.child,
                  1 - v,
                  size,
                  settle: math.sin(land * math.pi) * 1.5,
                  fadeFrom: .9,
                ),
              ],
              // 위에서 내려와 붙던 이전 방식
              // children: [IgnorePointer(child: old), _drop(widget.child, v, size)],
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

/// 연 모아보기 종이 안 달 칸의 위치. [_SummaryCalendarState._yearSheet]의 배치
/// (테이프 여백 8 + 종이 안쪽 여백 4/6 + 머리 줄 + 칸 + 요약 줄)와 같은 값으로 계산해,
/// 줌 연출이 실제 칸 자리로 정확히 들어가게 함.
class _YearGeometry {
  _YearGeometry(this.size)
    : cols = size.width > size.height * 1.3
          ? 6
          : size.width > size.height * .8
          ? 4
          : 3;

  static const header = 48.0;
  static const footer = 28.0;
  static const _tapeTop = 8.0;
  static const _paperX = 4.0;
  static const _paperY = 6.0;

  final Size size;

  /// 세로 화면은 3×4, 넓은 화면(태블릿·가로)은 4×3이나 6×2 - 칸이 포스터처럼 세로로
  /// 길쭉하게 남도록
  final int cols;
  int get rows => 12 ~/ cols;

  Rect get grid => Rect.fromLTRB(
    _paperX,
    _tapeTop + _paperY + header,
    size.width - _paperX,
    size.height - _paperY - footer,
  );

  Rect cell(int month) {
    final g = grid;
    final w = g.width / cols;
    final h = g.height / rows;
    final i = month - 1;
    return Rect.fromLTWH(
      g.left + (i % cols) * w,
      g.top + (i ~/ cols) * h,
      w,
      h,
    );
  }
}

/// 연 모아보기의 달 한 칸. 그 달에 본 공연 포스터를 최대 3장까지 살짝 기울여 겹쳐
/// 붙이고(늦은 공연이 위), 더 있으면 +N. 달 이름은 날짜 칸처럼 왼쪽 위 작은 딱지.
class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.month,
    required this.posters,
    required this.current,
    required this.dimmed,
  });

  final int month;
  final List<String?> posters;
  final bool current, dimmed;

  static const _maxStack = 3;

  Widget _sticker(String? poster) => Container(
    decoration: BoxDecoration(
      color: _diaryPaper,
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: Colors.white, width: 1.5),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .22),
          blurRadius: 3,
          offset: const Offset(1, 2),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: poster == null || poster.isEmpty
          ? _DayCell._ticketIcon()
          : AppNetworkImage(
              poster,
              memCacheWidth: 160,
              errorBuilder: (_) => _DayCell._ticketIcon(),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final count = posters.length;
    final shown = posters.take(_maxStack).toList();
    final attended = count > 0;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: LayoutBuilder(
        builder: (context, box) {
          const labelHeight = 18.0;
          final areaTop = labelHeight;
          final areaHeight = math.max(0.0, box.maxHeight - areaTop - 4);
          // 포스터 비율 3:4, 겹쳐 펼친 폭(약 1.8장)이 칸 안에 들어오게
          final width = math.min(
            box.maxWidth * (shown.length > 1 ? .5 : .62),
            areaHeight * .75,
          );
          final height = width * 4 / 3;
          final cx = box.maxWidth / 2;
          final cy = areaTop + areaHeight / 2;
          final spread = width * .42;
          // 칸마다 기울기를 조금씩 달리해 손으로 붙인 느낌
          const tilts = [-.13, .04, .12];
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (current)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: _ink.withValues(alpha: .06),
                      ),
                    ),
                  ),
                ),
              for (var i = 0; i < shown.length; i++)
                Positioned(
                  left: cx + (i - (shown.length - 1) / 2) * spread - width / 2,
                  top: cy - height / 2,
                  width: width,
                  height: height,
                  child: Transform.rotate(
                    angle: shown.length == 1
                        ? (month % 3 - 1) * .06
                        : tilts[(i + month) % tilts.length],
                    child: _sticker(shown[i]),
                  ),
                ),
              Positioned(
                left: 2,
                top: 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: attended
                      ? BoxDecoration(
                          color: _ink,
                          borderRadius: BorderRadius.circular(6),
                        )
                      : null,
                  child: Text(
                    '$month월',
                    style: TextStyle(
                      color: attended
                          ? Colors.white
                          : dimmed
                          ? _ink.withValues(alpha: .4)
                          : _ink,
                      fontSize: 12,
                      fontWeight: attended || current
                          ? FontWeight.w900
                          : FontWeight.w600,
                      decoration: current && !attended
                          ? TextDecoration.underline
                          : null,
                      decorationColor: _ink,
                      decorationThickness: 2,
                    ),
                  ),
                ),
              ),
              if (count > _maxStack)
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: _ink,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '+${count - _maxStack}',
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
        },
      ),
    );
  }
}
