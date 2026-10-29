import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'paper_style.dart';

import '../models/summary_report_data.dart';
import '../services/artist_search_service.dart';

// 다이어리(크라프트지) 분위기에 맞춘 갈색 잉크 - 남색 SaaS 톤이라 다른 앱처럼 보였음
const _ink = Color(0xFF3B2A20);
const _muted = Color(0xFF8A7765);
const _pink = Color(0xFFEA78B0);
const _purple = Color(0xFF8060FF);

String _number(num value) => value.toInt().toString().replaceAllMapped(
  RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
  (m) => '${m[1]},',
);
int _int(dynamic value) => (value as num?)?.toInt() ?? 0;

class SummaryReport extends StatefulWidget {
  const SummaryReport({
    super.key,
    required this.data,
    required this.period,
    required this.initialPage,
    required this.onPageChanged,
    required this.yearSelection,
    this.artistSearch,
  });
  final Map<String, dynamic> data;
  final String period;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final Map<String, String> yearSelection;
  final ArtistSearchService? artistSearch;

  @override
  State<SummaryReport> createState() => _SummaryReportState();
}

// [백엔드 수정] 보고서 무한 넘김 - 가상 페이지를 큰 수에서 시작해 양방향으로 계속 넘어가게 하고,
// 실제 페이지는 가상 페이지를 페이지 수로 나눈 나머지
const _reportPageCount = 2;
const _loopBase = 10000 * _reportPageCount;

class _SummaryReportState extends State<SummaryReport> {
  late final _controller = PageController(
    initialPage: _loopBase + widget.initialPage % _reportPageCount,
  );
  late int _page = widget.initialPage % _reportPageCount;
  late final _search = widget.artistSearch ?? BackendArtistSearchService();
  final _images = <String, Future<String?>>{};

  Future<String?> _image(ReportArtistGroup group, int index) {
    final name = group.names[index];
    final url = group.imageUrls[index];
    if (url?.isNotEmpty == true) return Future.value(url);
    return _images.putIfAbsent(name, () async {
      try {
        final matches = await _search.search(name);
        // Do not use an unrelated fuzzy search result as an artist's portrait.
        for (final artist in matches) {
          if (artist.name.trim().toLowerCase() == name.toLowerCase() &&
              artist.profileImageUrl.isNotEmpty) {
            return artist.profileImageUrl;
          }
        }
      } catch (_) {
        // A missing portrait must not prevent the report from rendering.
      }
      return null;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // 화살표는 지금 가상 페이지에서 한 장씩 - 넘기는 방향과 같은 쪽으로 이어짐
  void _go(int delta) {
    final current = _controller.page?.round() ?? _loopBase + _page;
    _controller.animateToPage(
      current + delta,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_int(widget.data['concert_count']) == 0) {
      return const Center(
        child: Text(
          '관람한 티켓을 등록하여 주세요',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    final months = reportMonths(widget.data, widget.period);
    final tickets = [
      for (final t in widget.data['ticket_details'] as List? ?? const [])
        if (t is Map) Map<String, dynamic>.from(t),
    ];
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (virtualPage) {
              final page = virtualPage % _reportPageCount;
              setState(() => _page = page);
              widget.onPageChanged(page);
            },
            itemBuilder: (context, virtualPage) =>
                virtualPage % _reportPageCount == 0
                ? _ReportPage(
                    page: 1,
                    children: [
                      _Metrics(data: widget.data),
                      const SizedBox(height: 14),
                      _MonthlyChart(
                        key: ValueKey('spend-${widget.period}'),
                        months: months,
                        tickets: tickets,
                        spending: true,
                        period: widget.period,
                        selection: widget.yearSelection,
                      ),
                    ],
                  )
                : _ReportPage(
                    page: 2,
                    children: [
                      _MonthlyChart(
                        key: ValueKey('visits-${widget.period}'),
                        months: months,
                        tickets: tickets,
                        spending: false,
                        period: widget.period,
                        selection: widget.yearSelection,
                      ),
                      const SizedBox(height: 14),
                      _ArtistPodium(
                        groups: reportArtistGroups(widget.data),
                        image: _image,
                      ),
                    ],
                  ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: '이전 보고서',
              onPressed: () => _go(-1),
              icon: const Icon(Icons.chevron_left, color: _ink),
            ),
            Text(
              '${_page + 1} / $_reportPageCount',
              style: const TextStyle(color: _ink, fontWeight: FontWeight.w700),
            ),
            IconButton(
              tooltip: '다음 보고서',
              onPressed: () => _go(1),
              icon: const Icon(Icons.chevron_right, color: _ink),
            ),
          ],
        ),
      ],
    );
  }
}

class _ReportPage extends StatelessWidget {
  const _ReportPage({required this.page, required this.children});
  final int page;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8, bottom: 8),
    child: LayoutBuilder(
      builder: (context, box) {
        // Both pages fill exactly the same canvas. Scale the entire layout only
        // on small screens, keeping labels, chart hit areas and portraits aligned.
        final scale = math.min(
          1.0,
          math.min(box.maxWidth / 300, box.maxHeight / 620),
        );
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            key: ValueKey('report-page-$page'),
            width: box.maxWidth / scale,
            height: box.maxHeight / scale,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: children[0]),
                children[1],
                Expanded(child: children[2]),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.data});
  final Map<String, dynamic> data;
  @override
  Widget build(BuildContext context) {
    final minutes = _int(data['total_runtime_minutes']);
    final missing = _int(data['runtime_missing_count']);
    final genres = (data['top_genres'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final genre = genres.isNotEmpty
        ? genres.join(', ')
        : data['top_genre'] as String? ?? '기록 없음';
    final time = minutes == 0 && missing > 0
        ? '정보 없음'
        : minutes < 60
        ? '$minutes분'
        : '${minutes ~/ 60}시간${minutes % 60 == 0 ? '' : ' ${minutes % 60}분'}';
    final count = _int(data['concert_count']);
    final spent = _int(data['total_spent']);
    Widget layout(double valueSize) {
      final cells = [
        _Metric(
          valueSize: valueSize,
          label: '관람한 공연',
          value: '${_number(count)}회',
          countUpTo: count,
          format: (v) => '${_number(v)}회',
          icon: Icons.confirmation_number_outlined,
          color: _pink,
        ),
        _Metric(
          valueSize: valueSize,
          label: '총 관람 시간',
          value: time,
          icon: Icons.schedule_rounded,
          color: _purple,
          note: missing > 0 ? '시간 미등록 $missing건 제외' : null,
        ),
        _Metric(
          valueSize: valueSize,
          label: '총 지출 금액',
          value: '${_number(spent)}원',
          countUpTo: spent,
          format: (v) => '${_number(v)}원',
          icon: Icons.payments_outlined,
          color: const Color(0xFF7F91EE),
        ),
        _Metric(
          valueSize: valueSize,
          label: '선호 장르',
          value: genre,
          icon: Icons.star_border_rounded,
          color: const Color(0xFFEEAD45),
          note: genres.length > 1 ? '공동 최다 관람 장르' : '가장 많이 본 장르',
          multiline: true,
        ),
      ];
      return Column(
        children: [
          for (var row = 0; row < 2; row++) ...[
            if (row > 0) const SizedBox(height: 10),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: cells[row * 2]),
                  const SizedBox(width: 10),
                  Expanded(child: cells[row * 2 + 1]),
                ],
              ),
            ),
          ],
        ],
      );
    }

    // 숫자 세 칸이 한 크기로 - 각자 FittedBox로 줄던 땐 "1회"는 38 그대로,
    // "165,000원"만 쪼그라들어 칸마다 제각각이었고 넓은 태블릿에선 너무 컸음.
    // 가장 긴 값이 칸 폭에 들어가는 크기를 모두에 씀.
    return LayoutBuilder(
      builder: (context, c) {
        final inner = (c.maxWidth - 10) / 2 - 28;
        final scaler = MediaQuery.textScalerOf(context);
        var widest = 0.0;
        for (final v in ['${_number(count)}회', time, '${_number(spent)}원']) {
          final w = (TextPainter(
            text: TextSpan(text: v, style: _Metric.valueStyle(_maxValueSize)),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
          )..layout()).width;
          widest = math.max(widest, w);
        }
        final fit = widest <= 0
            ? _maxValueSize
            : _maxValueSize * inner / widest;
        return layout(fit.clamp(16.0, _maxValueSize));
      },
    );
  }
}

/// 숫자 칸 글자 최대 크기(폰 기준 - 예전 23보다 크게, 38은 과했음)
const double _maxValueSize = 30;

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.countUpTo,
    this.format,
    this.note,
    this.multiline = false,
    this.valueSize = _maxValueSize,
  });
  final String label, value;
  final IconData icon;
  final Color color;

  /// 주면 0부터 이 값까지 숫자가 올라가는 연출([format]으로 표시)
  final int? countUpTo;
  final String Function(int)? format;
  final String? note;
  final bool multiline;

  /// [_Metrics]가 칸 폭에 맞춰 정해 주는 숫자 크기(세 칸 공통)
  final double valueSize;

  static TextStyle valueStyle(double size) => TextStyle(
    color: _ink,
    fontSize: size,
    fontWeight: FontWeight.w900,
    height: 1.1,
  );

  Widget _valueText(String text) => Text(text, style: valueStyle(valueSize));

  @override
  Widget build(BuildContext context) => _TapedCard(
    key: ValueKey('metric-$label'),
    tapeColor: color,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .16),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 19),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        // 숫자를 카드 아래쪽에 크게 - 작은 숫자 위로 빈 공간만 크던 것
        if (multiline)
          Expanded(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Tooltip(
                message: value,
                child: Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ink,
                    // 장르는 글자가 길어 숫자보다 작게(예전 22는 세 줄로 넘침)
                    fontSize: (valueSize * .6).clamp(14.0, 18.0),
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                  ),
                ),
              ),
            ),
          )
        else
          Expanded(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.bottomLeft,
                child: countUpTo == null
                    ? _valueText(value)
                    : TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: countUpTo!.toDouble()),
                        duration: const Duration(milliseconds: 700),
                        curve: Curves.easeOutCubic,
                        builder: (context, v, _) =>
                            _valueText(format!(v.round())),
                      ),
              ),
            ),
          ),
        if (note != null) ...[
          const SizedBox(height: 4),
          Text(note!, style: const TextStyle(color: _muted, fontSize: 10)),
        ],
      ],
    ),
  );
}

/// 크라프트지 위에 마스킹테이프로 붙인 크림색 메모지 카드.
class _TapedCard extends StatelessWidget {
  const _TapedCard({super.key, required this.tapeColor, required this.child});
  final Color tapeColor;
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Positioned.fill(
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
          decoration: _cardDecoration,
          child: child,
        ),
      ),
      Positioned(
        top: -7,
        left: 0,
        right: 0,
        child: Center(
          // 원색은 종이 톤과 안 어울려 베이지에 카드 색을 살짝만 섞음
          child: MaskingTape(tint: tapeColor, width: 48),
        ),
      ),
    ],
  );
}

final _cardDecoration = BoxDecoration(
  color: const Color(0xFFFFFBF3),
  borderRadius: BorderRadius.circular(10),
  border: Border.all(color: _ink.withValues(alpha: .08)),
  boxShadow: [
    BoxShadow(
      color: _ink.withValues(alpha: .14),
      blurRadius: 8,
      offset: const Offset(0, 3),
    ),
  ],
);

/// 보고서 데이터를 아직 못 받았을 때 보여주는 같은 배치의 뼈대 - 다른 기간의
/// 숫자를 잠깐 보여줬다가 바뀌던 것 대신.
class SummaryReportSkeleton extends StatefulWidget {
  const SummaryReportSkeleton({super.key});
  @override
  State<SummaryReportSkeleton> createState() => _SummaryReportSkeletonState();
}

class _SummaryReportSkeletonState extends State<SummaryReportSkeleton>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _bar(double width, double height) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: _ink.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(4),
    ),
  );

  Widget _card({required bool chart}) => Container(
    padding: const EdgeInsets.all(14),
    decoration: _cardDecoration,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _bar(chart ? 110 : 70, 12),
        const Spacer(),
        _bar(chart ? double.infinity : 90, chart ? 90 : 24),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: .55, end: 1).animate(_pulse),
    child: Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 56),
      child: Column(
        children: [
          for (var row = 0; row < 2; row++) ...[
            if (row > 0) const SizedBox(height: 10),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _card(chart: false)),
                  const SizedBox(width: 10),
                  Expanded(child: _card(chart: false)),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          Expanded(flex: 2, child: _card(chart: true)),
        ],
      ),
    ),
  );
}

class _MonthlyChart extends StatefulWidget {
  const _MonthlyChart({
    super.key,
    required this.months,
    required this.spending,
    required this.period,
    required this.selection,
    this.tickets = const [],
  });
  final List<ReportMonth> months;
  final bool spending;
  final String period;
  final Map<String, String> selection;
  // [백엔드 수정] 달을 누르면 그 달 공연 목록 팝업용(GET /summary의 ticket_details)
  final List<Map<String, dynamic>> tickets;
  @override
  State<_MonthlyChart> createState() => _MonthlyChartState();
}

class _MonthlyChartState extends State<_MonthlyChart> {
  int? _selected;
  OverlayEntry? _detail;

  @override
  void didUpdateWidget(covariant _MonthlyChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.months != widget.months) {
      _selected = null;
      _hideDetail();
    }
  }

  @override
  void dispose() {
    _hideDetail();
    super.dispose();
  }

  void _hideDetail() {
    _detail?.remove();
    _detail = null;
  }

  // 누른 달에 본 공연을 날짜순으로 팝업에 띄움(지출 차트는 가격도). 바깥을 누르면 닫힘
  void _showDetail(Offset anchor, ReportMonth month, Color color) {
    _hideDetail();
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final items = [
      for (final t in widget.tickets)
        if (DateTime.tryParse('${t['date']}') case final d?
            when d.year == month.month.year && d.month == month.month.month)
          t,
    ]..sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
    _detail = OverlayEntry(
      builder: (_) => _MonthDetail(
        anchor: anchor,
        month: month,
        items: items,
        spending: widget.spending,
        color: color,
        onDismiss: _hideDetail,
      ),
    );
    overlay.insert(_detail!);
  }

  @override
  Widget build(BuildContext context) {
    final years = widget.months.map((m) => m.month.year).toSet().toList()
      ..sort();
    final selectionKey = widget.spending ? 'spent' : 'count';
    final savedYear = int.tryParse(widget.selection[selectionKey] ?? '');
    final year = years.contains(savedYear) ? savedYear! : years.last;
    final months = widget.period == 'all'
        ? List.generate(
            12,
            (i) =>
                widget.months
                    .where(
                      (m) => m.month.year == year && m.month.month == i + 1,
                    )
                    .firstOrNull ??
                ReportMonth(DateTime(year, i + 1), 0, 0),
          )
        : widget.months;
    final values = months
        .map((m) => widget.spending ? m.spent : m.count)
        .toList();
    final maximum = values.fold<int>(0, math.max);
    final selected = (_selected ?? values.indexOf(maximum)).clamp(
      0,
      values.length - 1,
    );
    final color = widget.spending ? _pink : _purple;
    final title = widget.spending ? '월별 지출 금액' : '월별 관람 횟수';
    final caption = widget.period == 'all'
        ? '$year년'
        : '${months.first.month.year}.${months.first.month.month.toString().padLeft(2, '0')} – ${months.last.month.year}.${months.last.month.month.toString().padLeft(2, '0')}';
    final semantics = [
      for (var i = 0; i < months.length; i++)
        '${months[i].month.year}년 ${months[i].month.month}월 ${_number(values[i])}${widget.spending ? '원' : '회'}',
    ].join(', ');
    return Container(
      key: ValueKey(widget.spending ? 'spending-card' : 'attendance-card'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: _cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _ink,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          if (widget.period == 'all')
            SizedBox(
              height: 32,
              child: DropdownButton<int>(
                value: year,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: const TextStyle(color: _muted, fontSize: 12),
                items: [
                  for (final y in years)
                    DropdownMenuItem(value: y, child: Text('$y년')),
                ],
                onChanged: (y) => setState(() {
                  widget.selection[selectionKey] = '$y';
                  _selected = null;
                }),
              ),
            )
          else
            Text(caption, style: const TextStyle(color: _muted, fontSize: 11)),
          const SizedBox(height: 12),
          Text(
            widget.spending ? '(원)' : '(회)',
            style: const TextStyle(color: _muted, fontSize: 11),
          ),
          const SizedBox(height: 5),
          Expanded(
            child: Semantics(
              label: '$title. $semantics',
              child: LayoutBuilder(
                builder: (context, box) {
                  return GestureDetector(
                    onTapUp: (details) {
                      final left = widget.spending ? 50.0 : 26.0;
                      final step = (box.maxWidth - left - 4) / months.length;
                      final index = ((details.localPosition.dx - left) / step)
                          .floor()
                          .clamp(0, months.length - 1);
                      setState(() => _selected = index);
                      _showDetail(details.globalPosition, months[index], color);
                    },
                    child: CustomPaint(
                      key: ValueKey(
                        widget.spending ? 'spending-chart' : 'attendance-chart',
                      ),
                      size: Size(box.maxWidth, box.maxHeight),
                      painter: _ChartPainter(
                        months: months,
                        values: values,
                        spending: widget.spending,
                        selected: selected,
                        color: color,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (maximum == 0)
            const Text(
              '이 기간의 관람 기록이 없어요',
              style: TextStyle(color: _muted, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

// [백엔드 수정] 월별 차트 상세 팝업 - 보고서 카드와 같은 흰 카드 + 차트 색 포인트.
// 누른 자리 위(공간 없으면 아래)에 꼬리를 달아 띄우고, 공연은 최대 4건 + "외 N건"
class _MonthDetail extends StatelessWidget {
  const _MonthDetail({
    required this.anchor,
    required this.month,
    required this.items,
    required this.spending,
    required this.color,
    required this.onDismiss,
  });
  final Offset anchor;
  final ReportMonth month;
  final List<Map<String, dynamic>> items;
  final bool spending;
  final Color color;
  final VoidCallback onDismiss;

  static const _maxRows = 4;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(250.0, screen.width - 24);
    final left = (anchor.dx - width / 2).clamp(12.0, screen.width - width - 12);
    final above = anchor.dy > screen.height * .45;
    final tailX = (anchor.dx - left).clamp(20.0, width - 20);
    final summary = spending
        ? '${_number(month.spent)}원'
        : '${_number(month.count)}회';

    final card = Container(
      key: const ValueKey('month-detail'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEFDFE),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _ink.withValues(alpha: .14),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '${month.month.year}년 ${month.month.month}월',
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                summary,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: const Color(0xFFEBEBF1)),
          const SizedBox(height: 6),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '이 달엔 관람 기록이 없어요',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ),
          for (final t in items.take(_maxRows)) _row(t),
          if (items.length > _maxRows)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '외 ${items.length - _maxRows}건',
                style: const TextStyle(color: _muted, fontSize: 11),
              ),
            ),
        ],
      ),
    );
    final tail = Padding(
      padding: EdgeInsets.only(left: tailX - 7),
      child: CustomPaint(
        size: const Size(14, 7),
        painter: _TailPainter(pointDown: above),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => onDismiss(),
            onPanDown: (_) => onDismiss(),
          ),
        ),
        Positioned(
          left: left,
          width: width,
          top: above ? null : anchor.dy + 10,
          bottom: above ? screen.height - anchor.dy + 10 : null,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: above ? [card, tail] : [tail, card],
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(Map<String, dynamic> t) {
    final date = DateTime.tryParse('${t['date']}');
    final price = t['price'] as num?;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              date == null ? '' : '${date.month}.${date.day}',
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(
              '${t['concert_name'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _ink,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (spending && price != null) ...[
            const SizedBox(width: 8),
            Text(
              '${_number(price)}원',
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class _TailPainter extends CustomPainter {
  const _TailPainter({required this.pointDown});
  final bool pointDown;

  @override
  void paint(Canvas canvas, Size size) {
    final path = pointDown
        ? (Path()
            ..moveTo(0, 0)
            ..lineTo(size.width, 0)
            ..lineTo(size.width / 2, size.height))
        : (Path()
            ..moveTo(0, size.height)
            ..lineTo(size.width, size.height)
            ..lineTo(size.width / 2, 0));
    canvas.drawPath(path..close(), Paint()..color = const Color(0xFFFEFDFE));
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.pointDown != pointDown;
}

class _ChartPainter extends CustomPainter {
  const _ChartPainter({
    required this.months,
    required this.values,
    required this.spending,
    required this.selected,
    required this.color,
  });
  final List<ReportMonth> months;
  final List<int> values;
  final bool spending;
  final int selected;
  final Color color;

  TextPainter _text(
    String text,
    double size,
    Color color, {
    bool bold = false,
  }) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'Roboto',
        fontSize: size,
        color: color,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      spending ? 50 : 26,
      30,
      size.width - 4,
      size.height - 25,
    );
    final peak = values.fold<int>(0, math.max);
    final rawStep = math.max(1.0, peak / 4);
    final magnitude = math
        .pow(10, (math.log(rawStep) / math.ln10).floor())
        .toDouble();
    final tick = (rawStep / magnitude).ceil() * magnitude;
    final ceiling = tick * 4;
    final paint = Paint()
      ..color = const Color(0xFFEBEBF1)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = rect.bottom - rect.height * i / 4;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
      final v = tick * i;
      final label = _text(
        v >= 1000000 ? '${(v / 10000).round()}만' : _number(v),
        9,
        _muted,
      );
      label.paint(
        canvas,
        Offset(rect.left - label.width - 6, y - label.height / 2),
      );
    }
    final step = rect.width / values.length;
    final points = [
      for (var i = 0; i < values.length; i++)
        Offset(
          rect.left + step * (i + .5),
          rect.bottom - rect.height * values[i] / ceiling,
        ),
    ];
    if (spending) {
      final line = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        line.lineTo(point.dx, point.dy);
      }
      final fill = Path.from(line)
        ..lineTo(points.last.dx, rect.bottom)
        ..lineTo(points.first.dx, rect.bottom)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: .28),
              color.withValues(alpha: .01),
            ],
          ).createShader(rect),
      );
      canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
      for (final point in points) {
        canvas.drawCircle(point, 3.5, Paint()..color = color);
        canvas.drawCircle(
          point,
          3.5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = .7,
        );
      }
    } else {
      for (var i = 0; i < points.length; i++) {
        if (values[i] == 0) continue;
        final bar = Rect.fromLTRB(
          points[i].dx - step * .28,
          points[i].dy,
          points[i].dx + step * .28,
          rect.bottom,
        );
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            bar,
            topLeft: const Radius.circular(4),
            topRight: const Radius.circular(4),
          ),
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: i == selected
                  ? [color, color.withValues(alpha: .7)]
                  : [
                      color.withValues(alpha: .45),
                      color.withValues(alpha: .18),
                    ],
            ).createShader(bar),
        );
      }
    }
    for (var i = 0; i < months.length; i++) {
      final label = _text(
        '${months[i].month.month}월',
        months.length > 6 ? 8 : 10,
        _muted,
      );
      label.paint(
        canvas,
        Offset(points[i].dx - label.width / 2, rect.bottom + 9),
      );
    }
    final point = points[selected];
    if (spending) {
      final dash = Paint()
        ..color = color.withValues(alpha: .5)
        ..strokeWidth = 1;
      for (var y = point.dy + 5; y < rect.bottom; y += 5) {
        canvas.drawLine(
          Offset(point.dx, y),
          Offset(point.dx, math.min(y + 2, rect.bottom)),
          dash,
        );
      }
    }
    final label = _text(
      '${_number(values[selected])}${spending ? '원' : '회'}',
      10,
      Colors.white,
      bold: true,
    );
    final width = label.width + 16;
    final left = (point.dx - width / 2).clamp(
      0.0,
      math.max(0.0, size.width - width),
    );
    final top = point.dy - 30;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left.toDouble(), top, width, 23),
        const Radius.circular(8),
      ),
      Paint()..color = color,
    );
    canvas.drawPath(
      Path()
        ..moveTo(point.dx - 4, top + 22)
        ..lineTo(point.dx, top + 27)
        ..lineTo(point.dx + 4, top + 22)
        ..close(),
      Paint()..color = color,
    );
    label.paint(canvas, Offset(left + 8, top + (23 - label.height) / 2));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) => true;
}

class _ArtistPodium extends StatelessWidget {
  const _ArtistPodium({required this.groups, required this.image});
  final List<ReportArtistGroup> groups;
  final Future<String?> Function(ReportArtistGroup, int) image;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('artist-podium'),
    decoration: _cardDecoration,
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '관람 아티스트',
          style: TextStyle(
            color: _ink,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          groups.any((group) => group.names.length > 1)
              ? '프로필을 눌러 함께 순위에 오른 아티스트를 만나보세요'
              : '가장 자주 만난 아티스트',
          maxLines: 2,
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: groups.isEmpty
              ? const Center(
                  child: Text('관람 아티스트가 없어요', style: TextStyle(color: _muted)),
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    // Equal-width slots and a fixed gap guarantee no overlapping circles.
                    // Reserve label space before sizing the circles to the available height.
                    final diameter = math.max(
                      1.0,
                      math.min(
                        112.0,
                        math.min((box.maxWidth - 16) / 3, box.maxHeight - 88),
                      ),
                    );
                    return Center(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          for (final rank in [1, 0, 2]) ...[
                            if (rank != 1) const SizedBox(width: 8),
                            Expanded(
                              child: rank >= groups.length
                                  ? const SizedBox.shrink()
                                  : _Artist(
                                      key: ValueKey(
                                        '${groups[rank].count}:${groups[rank].names.join('|')}',
                                      ),
                                      rank: rank,
                                      group: groups[rank],
                                      image: image,
                                      maxDiameter: diameter,
                                      diameter:
                                          diameter *
                                          math.sqrt(
                                            groups[rank].count /
                                                groups.first.count,
                                          ),
                                    ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class _Artist extends StatefulWidget {
  const _Artist({
    super.key,
    required this.rank,
    required this.group,
    required this.image,
    required this.diameter,
    required this.maxDiameter,
  });
  final int rank;
  final ReportArtistGroup group;
  final Future<String?> Function(ReportArtistGroup, int) image;
  final double diameter, maxDiameter;

  @override
  State<_Artist> createState() => _ArtistState();
}

class _ArtistState extends State<_Artist> with AutomaticKeepAliveClientMixin {
  int _index = 0;
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final group = widget.group;
    final name = group.names[_index];
    final canCycle = group.names.length > 1;
    final color = widget.rank == 0
        ? _purple
        : widget.rank == 1
        ? _pink
        : const Color(0xFF8D9BD9);
    Widget placeholder() => ColoredBox(
      color: color.withValues(alpha: .12),
      child: Center(
        child: Icon(
          Icons.person_rounded,
          size: widget.diameter * .45,
          color: color,
        ),
      ),
    );
    return Tooltip(
      message: group.names.join(', '),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: widget.maxDiameter,
            child: Center(
              child: SizedBox(
                key: ValueKey('artist-circle-${widget.rank + 1}'),
                width: widget.diameter,
                height: widget.diameter,
                child: Semantics(
                  button: canCycle,
                  label: '$name 프로필',
                  hint: canCycle ? '다음 공동 순위 아티스트 보기' : null,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: canCycle
                        ? () => setState(
                            () => _index = (_index + 1) % group.names.length,
                          )
                        : null,
                    child: ClipOval(
                      child: FutureBuilder<String?>(
                        // Drop the previous snapshot immediately when cycling names so
                        // an old portrait never appears alongside the new artist name.
                        key: ValueKey(name),
                        future: widget.image(group, _index),
                        builder: (context, snapshot) {
                          final url = snapshot.data;
                          return url == null || url.isEmpty
                              ? placeholder()
                              : CachedNetworkImage(
                                  key: ValueKey(url),
                                  imageUrl: url,
                                  fit: BoxFit.cover,
                                  placeholder: (_, _) => placeholder(),
                                  errorWidget: (_, _, _) => placeholder(),
                                );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${widget.rank + 1}위',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 32,
            child: Center(
              child: Text(
                group.labelAt(_index),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${group.count}회',
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
