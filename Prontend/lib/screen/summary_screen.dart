import '../services/sound_effect_service.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../widgets/summary_calendar.dart';
import '../widgets/report_metric_chart.dart';
import '../services/api_client.dart';
import '../services/news_list_service.dart';
import '../services/news_card_identity.dart';
import '../services/favorites_store.dart';
import '../models/news_model.dart';
import '../services/ticket_refresh_bus.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/tab_nav_coordinator.dart';
import '../widgets/summary_region_map.dart' show summaryInk, summaryPaper;
import '../widgets/vendor_ticketing_buttons.dart' show vendorTicketingInfo;

// 결산 탭: 관람 기록과 기간별 통계를 표시합니다.
// 값은 `GET /summary` 원본 JSON을 그대로 읽음(SummaryModel 미사용).
typedef SummaryJsonLoader =
    Future<Map<String, dynamic>> Function(String period);

const _pageColor = Color(0xFFCEB99B);
const _accent = Color(0xFF8B5E3C);
const _accent2 = Color(0xFFB88A5A);

// 도넛/범례 색(인덱스 탭 색과 어울리는 톤)
const _palette = [
  Color(0xFF8B5E3C),
  Color(0xFFD9A066),
  Color(0xFF9DB8A5),
  Color(0xFFD4A5A0),
  Color(0xFF6F8F9D),
  Color(0xFFB88A5A),
];

Color _ticketingBrandColor(String name) {
  final normalized = name.toUpperCase().replaceAll(' ', '');
  for (final entry in vendorTicketingInfo.entries) {
    if (normalized.contains(entry.key)) return entry.value.color;
  }
  return _palette[0];
}

Future<Map<String, dynamic>> _defaultLoader(String period) =>
    ApiClient.instance.get('/summary?period=$period');

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key, this.loader = _defaultLoader});

  final SummaryJsonLoader loader;

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  static const _periods = {'6개월': '6m', '1년': '1y', '전체': 'all'};

  // 버튼이 가리키는(누른) 기간. 데이터가 아직 이전 기간이면 _shownPeriod와 다를 수 있음
  String _period = 'all';

  // 지금 화면에 보이는 데이터와 그 기간. 기간을 바꿔 다시 불러오는 동안에도 이전 값을 그대로 보여줌
  Map<String, dynamic>? _data;
  String _shownPeriod = 'all';
  Object? _error; // 첫 로딩 실패(보여줄 이전 값이 없을 때)만 화면 전체 오류로 표시
  bool _loading = false;
  int _requestId = 0;

  // 새 값을 못 불러왔을 때 잠깐 보여주는 안내(이 화면엔 Scaffold가 없어 스낵바 대신 직접 그림)
  String? _notice;
  Timer? _noticeTimer;

  // 기간을 바꿔 다시 불러와도 보던 페이지에 머물도록 현재 페이지를 화면 State에 보관
  int _page = 0;
  bool _calendarMode = true;
  final _calendarSelection = ValueNotifier<DateTime>(
    DateUtils.dateOnly(DateTime.now()),
  );

  // 연도 칩 선택(차트별). 페이지가 화면에서 사라졌다 다시 만들어져도 유지하려고 화면 State에 보관
  final Map<String, String> _yearSelection = {};
  late Future<List<NewsModel>> _newsFuture;
  Timer? _newsRefreshTimer;

  void _onNewsListUpdated() {
    final items = NewsListService.updates.value;
    if (mounted && items != null) {
      setState(() => _newsFuture = Future.value(items));
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    _newsFuture = _loadCalendarNews();
    NewsListService.updates.addListener(_onNewsListUpdated);
    _newsRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_loadCalendarNews().catchError((Object _) => <NewsModel>[]));
      }
    });
    TicketRefreshBus.tick.addListener(_load);
    FavoritesStore.instance.addListener(_refreshCalendarNews);
  }

  /// 소식탭과 동일하게 현재 팔로우 중인 아티스트의 소식만 캘린더에
  /// 사용합니다. 서버에는 언팔로우 이후에도 과거 feed가 남을 수 있으므로
  /// 단순히 GET /social/feed 결과를 그대로 쓰면 캘린더와 소식탭이 달라집니다.
  Future<List<NewsModel>> _loadCalendarNews() => NewsListService().load();

  void _refreshCalendarNews() {
    if (!mounted) return;
    setState(() {
      _newsFuture = _loadCalendarNews();
    });
  }

  // 마지막으로 보낸 요청의 결과만 반영(연달아 눌렀을 때 늦게 온 이전 응답이 덮어쓰지 않게)
  Future<void> _load() async {
    final id = ++_requestId;
    final period = _period;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.loader(period);
      if (!mounted || id != _requestId) return;
      setState(() {
        _data = data;
        _shownPeriod = period;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        if (_data == null) {
          _error = e;
        } else {
          // 이전 값을 그대로 두고 버튼도 그 기간으로 되돌림
          _period = _shownPeriod;
        }
      });
      if (_data != null) _showNotice('불러오지 못했어요. 이전 값을 보여드려요');
    }
  }

  void _showNotice(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  void dispose() {
    _newsRefreshTimer?.cancel();
    NewsListService.updates.removeListener(_onNewsListUpdated);
    TicketRefreshBus.tick.removeListener(_load);
    FavoritesStore.instance.removeListener(_refreshCalendarNews);
    _calendarSelection.dispose();
    _noticeTimer?.cancel();
    _dismissBubble();
    super.dispose();
  }

  // 누를 때마다 6개월 -> 1년 -> 전체 -> 6개월 순으로 바뀌는 단일 버튼
  String get _periodLabel =>
      _periods.entries.firstWhere((e) => e.value == _period).key;

  void _nextPeriod() {
    final values = _periods.values.toList();
    _period = values[(values.indexOf(_period) + 1) % values.length];
    _load();
  }

  Widget _content() {
    final data = _data;
    if (data == null) {
      if (_error != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '불러오지 못했어요\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: summaryInk),
              ),
              TextButton(onPressed: _load, child: const Text('다시 시도')),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (!_calendarMode && _int(data['concert_count']) == 0) {
      return const Center(
        child: Text(
          '공연을 관람하여 정보를 확인하세요!',
          style: TextStyle(
            color: summaryInk,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }
    // 새 값을 불러오는 동안은 이전 내용을 흐리게 두고 위에 얇은 진행 막대만 보여줌
    return Stack(
      children: [
        AnimatedOpacity(
          opacity: _loading ? 0.45 : 1,
          duration: const Duration(milliseconds: 150),
          child: FutureBuilder<List<NewsModel>>(
            future: _newsFuture,
            builder: (context, newsSnapshot) => _calendarMode
                ? SummaryCalendar(
                    tickets: _list(data['ticket_details']),
                    news: newsSnapshot.data ?? const [],
                    selection: _calendarSelection,
                    onNewsTap: (item) {
                      TabNavCoordinator.instance.pendingNewsCardKey =
                          newsCardKey(item);
                      TabNavCoordinator.instance.pendingNewsConcertId =
                          item.concertId;
                      TabNavCoordinator.instance.pendingNewsConcertName =
                          item.concert;
                      TabNavCoordinator.instance.requestTab(DiaryTab.news);
                    },
                    onTicketTap: (ticket) {
                      TabNavCoordinator.instance.pendingDiaryTicket = ticket;
                      TabNavCoordinator.instance.pendingDiaryTicketId =
                          ticket['ticket_id']?.toString();
                      TabNavCoordinator.instance.requestTab(DiaryTab.diary);
                    },
                  )
                : _Body(
                    data: data,
                    news: newsSnapshot.data ?? const [],
                    period: _shownPeriod,
                    calendarSelection: _calendarSelection,
                    initialPage: _page,
                    onPageChanged: (i) {
                      if (mounted) setState(() => _page = i);
                    },
                    yearSelection: _yearSelection,
                  ),
          ),
        ),
        if (_notice != null)
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: summaryInk,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  _notice!,
                  style: const TextStyle(color: summaryPaper, fontSize: 12),
                ),
              ),
            ),
          ),
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              minHeight: 3,
              color: summaryInk,
              backgroundColor: Colors.transparent,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 실제 결산탭처럼 일기 프레임 안에 그림(옆 인덱스 탭은 결산 탭 활성)
    return DiaryPageFrame(
      isTabRoot: true,
      pageTextureEnabled: false,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.summary),
      child: Material(
        color: _pageColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                child: _ModeButton(
                  label: _calendarMode ? '캘린더' : '${_periodLabel} 보고서',
                  active: true,
                  onTap: () {
                    unawaited(
                      SoundEffectService.instance.play(SoundEffect.bookSip),
                    );
                    _advanceSummaryMode();
                  },
                ),
              ),
              const SizedBox(height: 16),
              Expanded(child: _content()),
            ],
          ),
        ),
      ),
    );
  }

  void _advanceSummaryMode() {
    if (_calendarMode) {
      setState(() {
        _calendarMode = false;
        _period = '6m';
        _page = 0;
      });
      _load();
    } else if (_period == '6m') {
      setState(() {
        _period = '1y';
        _page = 0;
      });
      _load();
    } else if (_period == '1y') {
      setState(() {
        _period = 'all';
        _page = 0;
      });
      _load();
    } else {
      setState(() {
        _calendarMode = true;
        _page = 0;
      });
    }
  }
}

// ---- 값 읽기 헬퍼 ----

List<Map<String, dynamic>> _list(dynamic v) =>
    (v as List? ?? const []).whereType<Map<String, dynamic>>().toList();

int _int(dynamic v) => v is num ? v.toInt() : 0;

String _won(num v) =>
    '${v.round().toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}원';

const _weekdayNames = ['월', '화', '수', '목', '금', '토', '일'];

String _manwon(int v) => v >= 10000
    ? '${(v / 10000).toStringAsFixed(v % 10000 == 0 ? 0 : 1)}만'
    : '$v';

String _pct(dynamic v) => v is num ? '${v.round()}%' : '-';

String _hours(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return h == 0 ? '$m분' : (m == 0 ? '$h시간' : '$h시간 $m분');
}

// ---- 페이지 구성 ----

class _Body extends StatelessWidget {
  const _Body({
    required this.calendarSelection,
    required this.news,
    required this.data,
    required this.period,
    required this.initialPage,
    required this.onPageChanged,
    required this.yearSelection,
  });

  final ValueNotifier<DateTime> calendarSelection;
  final List<NewsModel> news;
  final Map<String, dynamic> data;
  final String period;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final Map<String, String> yearSelection;

  @override
  Widget build(BuildContext context) {
    final monthly = _list(data['monthly_stats']);
    final tickets = _list(data['ticket_details']);
    final weekdays = (data['weekday_counts'] as List? ?? const [])
        .map(_int)
        .toList();
    final sites = _list(data['ticketing_sites']);
    final venues = _list(data['top_venues']);
    final artists = _list(data['artists']).take(5).toList();
    final maxSpend = data['max_spend'] as Map<String, dynamic>?;
    final busiest = data['busiest_month'] as Map<String, dynamic>?;
    final topSpendArtist = data['top_spend_artist'] as Map<String, dynamic>?;
    final heard = data['most_heard_song'] as Map<String, dynamic>?;
    final rare = data['rarest_song'] as Map<String, dynamic>?;
    final newArtists = (data['new_artists'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final newArtistsByYear = <int, List<String>>{
      for (final y in _list(data['new_artists_by_year']))
        _int(y['year']): (y['artists'] as List? ?? const [])
            .whereType<String>()
            .toList(),
    };
    final genres = (data['top_genres'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final artistColors = List<Color>.generate(
      artists.length,
      (index) => Color.lerp(
        _accent,
        Colors.white,
        artists.length <= 1 ? 0 : index / (artists.length - 1) * .45,
      )!,
    );

    String monthLabel(Map<String, dynamic> m) {
      final parts = (m['month'] as String? ?? '').split('-');
      if (parts.length != 2) return '';
      return parts[1] == '01'
          ? "${parts[0].substring(2)}.${parts[1]}"
          : parts[1];
    }

    // 막대를 누르면 그 달에 본 공연을 말풍선으로 보여줌(지출 차트는 가격 포함)
    void showMonth(String month, Offset pos, {required bool spend}) {
      final items = [
        for (final t in tickets)
          if ((t['date'] as String? ?? '').startsWith(month)) t,
      ];
      final mm = int.tryParse(month.length >= 7 ? month.substring(5, 7) : '');
      final label = mm == null ? month : '$mm월';
      final total = items.fold<int>(0, (s, t) => s + _int(t['price']));
      _showTickets(
        context,
        pos,
        spend ? '$label · ${_manwon(total)}' : '$label · ${items.length}회',
        items,
        withPrice: spend,
      );
    }

    // 도넛 조각/범례를 누르면 그 쪽 공연을 말풍선으로 보여줌
    void showSegment(String field, String value, String label, Offset pos) {
      final items = [
        for (final t in tickets)
          if (t[field] == value) t,
      ];
      _showTickets(context, pos, '$label · ${items.length}회', items);
    }

    // 전체 기간은 연도 탭으로 골라 1~12월 차트를 보고, 6개월/1년은 이어서 한 차트로 그림
    Widget monthChart(
      String title,
      String key,
      Color color, {
      String Function(int)? format,
    }) {
      final spend = key == 'spent';
      if (period != 'all') {
        return _Bars(
          values: [for (final m in monthly) _int(m[key])],
          labels: [for (final m in monthly) monthLabel(m)],
          color: color,
          format: format,
          scroll: false,
          onBarTap: (i, pos) =>
              showMonth('${monthly[i]['month']}', pos, spend: spend),
        );
      }
      final byYear = <String, List<int>>{};
      for (final m in monthly) {
        final parts = (m['month'] as String? ?? '').split('-');
        if (parts.length != 2) continue;
        final month = int.tryParse(parts[1]);
        if (month == null || month < 1 || month > 12) continue;
        (byYear.putIfAbsent(parts[0], () => List.filled(12, 0)))[month - 1] =
            _int(m[key]);
      }
      if (byYear.isEmpty) return const _Empty();
      final yearMax = byYear.values
          .expand((v) => v)
          .reduce((a, b) => a > b ? a : b);
      return _YearTabbedBars(
        title: title,
        byYear: byYear,
        color: color,
        format: format,
        maxValue: yearMax,
        selection: yearSelection,
        selectionKey: 'month_$key',
        onBarTap: (year, monthIndex, pos) => showMonth(
          '$year-${(monthIndex + 1).toString().padLeft(2, '0')}',
          pos,
          spend: spend,
        ),
      );
    }

    final weekdayMax = weekdays.isEmpty
        ? 0
        : weekdays.reduce((a, b) => a > b ? a : b);

    _CardSpec metric(
      String title,
      List<(String, double, String)> rows, {
      String? note,
    }) => _CardSpec(
      title: title,
      flex: 1,
      minHeight: 300,
      child: ReportMetricChart(rows: rows, note: note),
    );
    final metricCards = <_CardSpec>[
      metric('관람 횟수', [
        (
          '관람',
          _int(data['concert_count']).toDouble(),
          '${_int(data['concert_count'])}회',
        ),
      ]),
      metric('총 지출', [
        (
          '총 지출',
          _int(data['total_spent']).toDouble(),
          _won(_int(data['total_spent'])),
        ),
      ]),
      if (data['avg_ticket_price'] != null || maxSpend != null)
        metric(
          '티켓 가격 비교',
          [
            if (data['avg_ticket_price'] != null)
              (
                '평균',
                _int(data['avg_ticket_price']).toDouble(),
                _won(_int(data['avg_ticket_price'])),
              ),
            if (maxSpend != null)
              (
                '최고 지출',
                _int(maxSpend['price']).toDouble(),
                _won(_int(maxSpend['price'])),
              ),
          ],
          note: maxSpend == null
              ? null
              : '최고 지출 공연: ${maxSpend['concert_name']}',
        ),
      _CardSpec(
        title: '가장 많이 본 장르',
        note: '공동 최다 장르 · 장르별 횟수와 비중은 제공되지 않습니다.',
        flex: 1,
        minHeight: 300,
        child: _NewArtists(names: genres),
      ),
      metric('총 관람 시간', [
        (
          '관람 시간',
          _int(data['total_runtime_minutes']).toDouble(),
          _hours(_int(data['total_runtime_minutes'])),
        ),
      ], note: '시간 정보가 없는 티켓 ${_int(data['runtime_missing_count'])}장'),
      metric('들은 곡', [
        (
          '집계된 곡',
          _int(data['song_count']).toDouble(),
          '${_int(data['song_count'])}곡',
        ),
        (
          '추정된 곡',
          _int(data['song_count_estimated']).toDouble(),
          '${_int(data['song_count_estimated'])}곡',
        ),
      ], note: '집계값과 추정값을 구분해 표시합니다.'),
      metric('남긴 사진', [
        (
          '사진',
          _int(data['photo_count']).toDouble(),
          '${_int(data['photo_count'])}장',
        ),
      ]),
      metric('남긴 일기', [
        (
          '일기',
          _int(data['diary_count']).toDouble(),
          '${_int(data['diary_count'])}개',
        ),
      ]),
      if (busiest != null)
        metric('한 달 최다 관람', [
          (
            '${busiest['month']}',
            _int(busiest['count']).toDouble(),
            '${busiest['count']}회',
          ),
        ]),
      if (topSpendArtist != null)
        metric('가장 많이 쓴 아티스트', [
          (
            '${topSpendArtist['name']}',
            _int(topSpendArtist['amount']).toDouble(),
            _won(_int(topSpendArtist['amount'])),
          ),
        ]),
      if (heard != null)
        metric('가장 많이 들은 곡', [
          (
            '${heard['name']}',
            _int(heard['count']).toDouble(),
            '${heard['count']}번',
          ),
        ], note: '${heard['artist'] ?? ''}'),
      if (rare != null)
        _CardSpec(
          title: '가장 희귀한 곡',
          flex: 1,
          minHeight: 300,
          note: '${rare['name']} · ${rare['concert_name']}',
          child: _DonutBlock(
            '예상 출현',
            (rare['probability'] as num) * 100,
            '그 외',
            100 - (rare['probability'] as num) * 100,
          ),
        ),
    ];
    // 전체 기간의 연도 선택 차트는 칩이 제목 줄에 들어가므로 카드 전체를 차트가 그림
    _CardSpec monthSpec(String title, Widget chart) => _CardSpec(
      title: title,
      flex: 3,
      minHeight: 230,
      narrowMinHeight: 175,
      fullCard: chart is _YearTabbedBars ? chart : null,
      child: chart,
    );

    final sections = <_PageOfCards>[
      // 1페이지: 요약 / 기록
      _PageOfCards(cards: [...metricCards]),
      // 2페이지: 월별 관람 / 월별 지출 / 요일별
      _PageOfCards(
        cards: [
          monthSpec('월별 관람 수', monthChart('월별 관람 수', 'concert_count', _accent)),
          monthSpec(
            '월별 지출',
            monthChart('월별 지출', 'spent', _accent2, format: _manwon),
          ),
          _CardSpec(
            title: '요일별 공연 수',
            flex: 3,
            minHeight: 230,
            narrowMinHeight: 175,
            child: weekdays.isEmpty
                ? const _Empty()
                : _HBars(
                    labelWidth: 28,
                    centerLabel: true,
                    highlightMax: true,
                    items: [
                      for (var i = 0; i < weekdays.length && i < 7; i++)
                        (_weekdayNames[i], weekdays[i], '${weekdays[i]}회'),
                    ],
                    maxValue: weekdayMax,
                  ),
          ),
        ],
      ),
      // 3페이지: 예매처 / 공연장 / 선호 비율
      _PageOfCards(
        cards: [
          _CardSpec(
            title: '예매처 비중',
            note: '예매처 모름 ${_int(data['ticketing_site_unknown_count'])}장 제외',
            flex: 3,
            minHeight: 190,
            narrowMinHeight: 150,
            child: _SitesDonut(sites: sites),
          ),
          _CardSpec(
            title: '가장 많이 간 공연장',
            flex: 2,
            minHeight: 130,
            narrowMinHeight: 110,
            child: _HBars(
              items: [
                for (final v in venues)
                  ('${v['name']}', _int(v['count']), '${_int(v['count'])}회'),
              ],
            ),
          ),
          _CardSpec(
            title: '선호 비율',
            flex: 3,
            minHeight: 210,
            narrowMinHeight: 165,
            child: Row(
              children: [
                Expanded(
                  child: _DonutBlock(
                    '스탠딩',
                    data['standing_percent'],
                    '좌석',
                    data['seated_percent'],
                    onSegmentTap: (i, pos) => showSegment(
                      'seat',
                      i == 0 ? 'standing' : 'seated',
                      i == 0 ? '스탠딩' : '좌석',
                      pos,
                    ),
                  ),
                ),
                Expanded(
                  child: _DonutBlock(
                    '첫콘',
                    data['first_day_percent'],
                    '막콘',
                    data['last_day_percent'],
                    onSegmentTap: (i, pos) => showSegment(
                      'day',
                      i == 0 ? 'first' : 'last',
                      i == 0 ? '첫콘' : '막콘',
                      pos,
                    ),
                  ),
                ),
                Expanded(
                  child: _DonutBlock(
                    '국내',
                    data['origin_domestic_percent'],
                    '내한',
                    data['origin_foreign_percent'],
                    onSegmentTap: (i, pos) => showSegment(
                      'origin',
                      i == 0 ? 'domestic' : 'foreign',
                      i == 0 ? '국내' : '내한',
                      pos,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      // 4페이지: 관람 아티스트 / 처음 본 아티스트
      _PageOfCards(
        cards: [
          _CardSpec(
            title: '관람 아티스트',
            flex: 3,
            minHeight: 200,
            narrowMinHeight: 160,
            child: _HBars(
              colors: artistColors,
              items: [
                for (final a in artists)
                  ('${a['name']}', _int(a['count']), '${_int(a['count'])}회'),
              ],
            ),
          ),
          // 전체 기간은 모두가 "처음"이라 의미가 없어서, 처음 본 해별로 나눠 보여줌
          if (period == 'all' && newArtistsByYear.isNotEmpty)
            _CardSpec(
              title: '처음 본 아티스트',
              flex: 3,
              minHeight: 150,
              narrowMinHeight: 130,
              fullCard: _YearNewArtists(
                byYear: newArtistsByYear,
                selection: yearSelection,
              ),
              child: const SizedBox.shrink(),
            )
          else
            _CardSpec(
              title: '처음 본 아티스트 ${_int(data['new_artist_count'])}명',
              flex: 3,
              minHeight: 130,
              narrowMinHeight: 110,
              child: _NewArtists(names: newArtists),
            ),
        ],
      ),
    ];
    final allCards = [for (final section in sections) ...section.cards];
    final groups = <String, List<_CardSpec>>{
      '관람': [],
      '지출': [],
      '곡': [],
      '아티스트': [],
      '취향': [],
      '기록': [],
    };
    for (final card in allCards) {
      final title = card.title;
      final topic = switch (title) {
        '총 지출' || '티켓 가격 비교' || '월별 지출' || '가장 많이 쓴 아티스트' || '예매처 비중' => '지출',
        '들은 곡' || '가장 많이 들은 곡' || '가장 희귀한 곡' => '곡',
        '가장 많이 본 장르' || '선호 비율' => '취향',
        '남긴 사진' || '남긴 일기' => '기록',
        _ when title.contains('아티스트') => '아티스트',
        _ => '관람',
      };
      groups[topic]!.add(card);
    }
    final pages = [
      for (final group in groups.entries)
        if (group.value.isNotEmpty)
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  group.key,
                  style: const TextStyle(
                    color: summaryInk,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Expanded(child: _PageOfCards(cards: group.value)),
            ],
          ),
    ];
    return _Pager(
      pages: pages,
      initialPage: initialPage,
      onPageChanged: onPageChanged,
    );
  }
}

// 페이지 넘김(좌우 스와이프) + 하단 점 표시
class _Pager extends StatefulWidget {
  const _Pager({
    required this.pages,
    required this.initialPage,
    required this.onPageChanged,
  });

  final List<Widget> pages;
  final int initialPage;
  final ValueChanged<int> onPageChanged;

  @override
  State<_Pager> createState() => _PagerState();
}

class _PagerState extends State<_Pager> {
  // 첫 페이지에서 오른쪽으로, 마지막 페이지에서 왼쪽으로도 넘어가도록(순환) 가운데쯤에서 시작하고
  // 페이지 번호는 나머지 연산으로 구함
  static const _loopBase = 1000;

  int get _count => widget.pages.length;

  late final _controller = PageController(
    initialPage: _loopBase * _count + widget.initialPage,
  );
  late int _page = widget.initialPage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // 점을 눌렀을 때 현재 위치에서 가장 가까운 해당 페이지로 이동
  void _goTo(int target) {
    final current = _controller.page?.round() ?? _loopBase * _count;
    final base = current - (current % _count);
    _controller.animateToPage(
      base + target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (raw) {
              final i = raw % _count;
              widget.onPageChanged(i);
              setState(() => _page = i);
            },
            itemBuilder: (context, raw) => widget.pages[raw % _count],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '이전 보고서',
                onPressed: () => _goTo((_page - 1 + _count) % _count),
                icon: const Icon(Icons.chevron_left, color: summaryInk),
              ),
              Text(
                '${_page + 1} / $_count',
                style: const TextStyle(
                  color: summaryInk,
                  fontWeight: FontWeight.w700,
                ),
              ),
              IconButton(
                tooltip: '다음 보고서',
                onPressed: () => _goTo((_page + 1) % _count),
                icon: const Icon(Icons.chevron_right, color: summaryInk),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- 카드/페이지 ----

class _CardSpec {
  const _CardSpec({
    required this.title,
    required this.child,
    required this.flex,
    required this.minHeight,
    this.narrowMinHeight,
    this.fullCard,
    this.note,
  });

  final String title;
  final String? note;
  final Widget child;

  // 페이지 높이가 충분하면 flex 비율로 남는 공간을 나눠 채우고, 모자라면 minHeight로 스크롤
  final int flex;
  final double minHeight;

  // 폭이 좁아 타일이 2열로 쌓이는 화면(폰)에서 쓸 높이. 없으면 minHeight
  final double? narrowMinHeight;

  // 제목 줄까지 직접 그리는 카드(있으면 _Card 대신 이것을 씀)
  final Widget? fullCard;
}

class _PageOfCards extends StatelessWidget {
  const _PageOfCards({required this.cards});
  final List<_CardSpec> cards;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        const gap = 8.0;
        // 주제 전체를 고정 격자로 보여줍니다. 작은 화면에서는 카드 내부의
        // 좌표계를 함께 축소해 차트와 터치 영역이 잘리거나 넘치지 않게 합니다.
        final columns = cards.length >= 4 || box.maxWidth > box.maxHeight
            ? 2
            : 1;
        final rows = (cards.length / columns).ceil();
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
          child: Column(
            children: [
              for (var row = 0; row < rows; row++) ...[
                if (row > 0) const SizedBox(height: gap),
                Expanded(
                  child: Row(
                    children: [
                      for (var col = 0; col < columns; col++) ...[
                        if (col > 0) const SizedBox(width: gap),
                        Expanded(
                          child: row * columns + col >= cards.length
                              ? const SizedBox.shrink()
                              : LayoutBuilder(
                                  builder: (_, cell) {
                                    final card = cards[row * columns + col];
                                    final scale = math.min(
                                      1.0,
                                      math.min(
                                        cell.maxWidth / 200,
                                        cell.maxHeight /
                                            (card.child is ReportMetricChart
                                                ? 150
                                                : 210),
                                      ),
                                    );
                                    return FittedBox(
                                      fit: BoxFit.contain,
                                      child: SizedBox(
                                        width: cell.maxWidth / scale,
                                        height: cell.maxHeight / scale,
                                        child:
                                            card.fullCard ?? _Card(spec: card),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.spec});

  final _CardSpec spec;

  @override
  Widget build(BuildContext context) =>
      _CardShell(title: spec.title, note: spec.note, child: spec.child);
}

// 카드 바탕 + 제목 줄(오른쪽에 trailing을 둘 수 있음) + 내용
class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.title,
    required this.child,
    this.note,
    this.trailing,
  });

  final String title;
  final String? note;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final titleText = Text(
      title,
      style: const TextStyle(
        color: summaryInk,
        fontWeight: FontWeight.w800,
        fontSize: 16,
      ),
    );
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAF0),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD2BFA7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          trailing == null
              ? titleText
              : Row(
                  children: [
                    titleText,
                    const SizedBox(width: 8),
                    Expanded(child: trailing!),
                  ],
                ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                note!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: const Color(0xFF715849), fontSize: 12),
              ),
            ),
          const SizedBox(height: 6),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Center(
    child: Text('-', style: TextStyle(color: summaryInk.withValues(alpha: .6))),
  );
}

// ---- 그래프 탭 말풍선 ----

typedef _TicketRow = Map<String, dynamic>;

OverlayEntry? _bubbleEntry;

void _dismissBubble() {
  _bubbleEntry?.remove();
  _bubbleEntry = null;
}

// 누른 자리 위(자리가 없으면 아래)에 간단한 말풍선을 띄우고, 바깥을 누르면 닫음
void _showBubble(
  BuildContext context,
  Offset anchor,
  String title,
  List<String> lines,
) {
  _dismissBubble();
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  _bubbleEntry = OverlayEntry(
    builder: (_) => _BubbleLayer(
      anchor: anchor,
      title: title,
      lines: lines,
      onDismiss: _dismissBubble,
    ),
  );
  overlay.insert(_bubbleEntry!);
}

// 티켓 목록을 "제목 + 공연명 최대 3줄(+외 N건)"로 보여줌. 지출 차트는 공연명 옆에 가격도 표시
void _showTickets(
  BuildContext context,
  Offset anchor,
  String title,
  List<_TicketRow> items, {
  bool withPrice = false,
}) {
  if (items.isEmpty) return;
  final lines = [
    for (final t in items.take(3))
      withPrice && t['price'] != null
          ? '${t['concert_name']} · ${_won(_int(t['price']))}'
          : '${t['concert_name']}',
  ];
  if (items.length > 3) lines.add('외 ${items.length - 3}건');
  _showBubble(context, anchor, title, lines);
}

class _BubbleLayer extends StatelessWidget {
  const _BubbleLayer({
    required this.anchor,
    required this.title,
    required this.lines,
    required this.onDismiss,
  });

  final Offset anchor;
  final String title;
  final List<String> lines;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = math.min(230.0, size.width - 24);
    final left = (anchor.dx - width / 2).clamp(12.0, size.width - width - 12);
    final above = anchor.dy > 170;
    final tailX = (anchor.dx - left).clamp(18.0, width - 18);
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: summaryInk,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: summaryPaper,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: summaryPaper.withValues(alpha: .9),
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
    final tail = Padding(
      padding: EdgeInsets.only(left: tailX - 7),
      child: CustomPaint(
        size: const Size(14, 7),
        painter: _TailPainter(summaryInk, pointDown: above),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
          ),
        ),
        Positioned(
          left: left,
          width: width,
          top: above ? null : anchor.dy + 4,
          bottom: above ? size.height - anchor.dy + 4 : null,
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
}

class _TailPainter extends CustomPainter {
  _TailPainter(this.color, {required this.pointDown});

  final Color color;
  final bool pointDown;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (pointDown) {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height);
    } else {
      path
        ..moveTo(0, size.height)
        ..lineTo(size.width, size.height)
        ..lineTo(size.width / 2, 0);
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TailPainter old) =>
      old.color != color || old.pointDown != pointDown;
}

// ---- 숫자 타일 ----

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, {this.sub, this.inline = false});

  final String label;
  final String value;
  final String? sub;

  // true면 타일이 낮을 때 값 옆에 보조 글자를 같은 줄로 붙여 값이 보이게 함
  final bool inline;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // 타일이 클수록(태블릿) 글자도 같이 키우고, 높이가 넉넉하면 보조 글자를 값 아래 줄에 둠
        final k = math
            .min(box.maxHeight / 64, box.maxWidth / 135)
            .clamp(1.0, 1.5);
        final roomy = box.maxHeight >= 74 * k.clamp(1.0, 1.2);
        final sideBySide = inline && !roomy;
        final valueText = FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: TextStyle(
              color: summaryInk,
              fontWeight: FontWeight.w800,
              fontSize: (sideBySide ? 24 : 26) * k,
            ),
          ),
        );
        final subText = sub == null
            ? null
            : Text(
                sub!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color(0xFF715849),
                  fontSize: 12 * k,
                ),
              );
        return Container(
          padding: EdgeInsets.symmetric(horizontal: 10 * k, vertical: 5 * k),
          decoration: BoxDecoration(
            color: const Color(0xFFF0E5D5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color(0xFF634B3E),
                  fontWeight: FontWeight.w600,
                  fontSize: 13 * k,
                ),
              ),
              if (sideBySide)
                Flexible(
                  child: Row(
                    children: [
                      Flexible(child: valueText),
                      if (subText != null) ...[
                        const SizedBox(width: 6),
                        Flexible(child: subText),
                      ],
                    ],
                  ),
                )
              else ...[
                SizedBox(height: 2 * k),
                // 타일이 낮아도 넘치지 않게 값이 남는 높이 안에서 줄어듦
                Flexible(child: valueText),
                if (subText != null) Flexible(child: subText),
              ],
            ],
          ),
        );
      },
    );
  }
}

// 타일들을 주어진 높이를 꽉 채우는 격자로 배치(영역 모양에 따라 2열/4열)
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.tiles, this.columns});

  final List<Widget> tiles;
  final int? columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // 넓고 낮은 영역이면 4열, 폰이나 태블릿 세로처럼 좁고 높으면 2열(타일이 길쭉해지지 않게)
        final wide4 =
            box.maxWidth >= 480 &&
            (box.maxWidth - 24) / 4 >= (box.maxHeight - 8) / 2 * 0.9;
        final cols = columns ?? (wide4 ? 4 : 2);
        final rows = (tiles.length / cols).ceil();
        return Column(
          children: [
            for (var r = 0; r < rows; r++) ...[
              if (r > 0) const SizedBox(height: 8),
              Expanded(
                child: Row(
                  children: [
                    for (var c = 0; c < cols; c++) ...[
                      if (c > 0) const SizedBox(width: 8),
                      Expanded(
                        child: r * cols + c < tiles.length
                            ? tiles[r * cols + c]
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

// ---- 도넛 ----

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.values, this.colors);

  final List<double> values;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.17;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = summaryInk.withValues(alpha: .12);
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    final total = values.fold<double>(0, (s, v) => s + v);
    if (total <= 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final sweep = math.pi * 2 * values[i] / total;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..color = colors[i % colors.length],
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.values != values || old.colors != colors;
}

// 도넛 + 가운데 글자. 주어진 영역 안에서 가장 큰 정사각형으로 그림
class _Donut extends StatelessWidget {
  const _Donut({
    required this.values,
    required this.center,
    this.onSegmentTap,
    this.colors,
  });

  final List<double> values;
  final Widget center;
  final List<Color>? colors;

  // 도넛을 눌렀을 때 몇 번째 조각인지(시계 방향, 12시부터)와 화면 좌표를 알려줌
  final void Function(int index, Offset globalPosition)? onSegmentTap;

  void _handleTap(TapUpDetails d, double size) {
    final total = values.fold<double>(0, (s, v) => s + v);
    if (onSegmentTap == null || total <= 0) return;
    final v = d.localPosition - Offset(size / 2, size / 2);
    if (v.distance > size / 2) return;
    final angle = (math.atan2(v.dy, v.dx) + math.pi / 2) % (math.pi * 2);
    var fraction = angle / (math.pi * 2);
    for (var i = 0; i < values.length; i++) {
      final share = values[i] / total;
      if (fraction < share) {
        onSegmentTap!(i, d.globalPosition);
        return;
      }
      fraction -= share;
    }
    onSegmentTap!(values.length - 1, d.globalPosition);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = math.max(
          40.0,
          math.min(box.maxWidth, box.maxHeight).toDouble(),
        );
        return Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _handleTap(d, size),
            child: SizedBox(
              width: size,
              height: size,
              child: CustomPaint(
                painter: _DonutPainter(values, colors ?? _palette),
                child: Padding(
                  padding: EdgeInsets.all(size * 0.2),
                  child: Center(child: center),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot(this.color, this.text, {this.onTapUp});

  final Color color;
  final String text;
  final void Function(TapUpDetails)? onTapUp;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: onTapUp,
      child: _row(),
    );
  }

  Widget _row() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: summaryInk,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// 두 값이 나뉘는 도넛 하나(대상이 없으면 빈 고리와 '-')
class _DonutBlock extends StatelessWidget {
  const _DonutBlock(
    this.labelA,
    this.a,
    this.labelB,
    this.b, {
    this.onSegmentTap,
  });

  final String labelA;
  final dynamic a;
  final String labelB;
  final dynamic b;
  final void Function(int index, Offset globalPosition)? onSegmentTap;

  @override
  Widget build(BuildContext context) {
    final pa = a is num ? (a as num).toDouble() : null;
    final pb = b is num ? (b as num).toDouble() : null;
    final hasData = pa != null && pb != null;
    final aLeads = hasData && pa >= pb;
    final leadLabel = aLeads ? labelA : labelB;
    final leadValue = aLeads ? a : b;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Expanded(
            child: _Donut(
              values: hasData ? [pa, pb] : const [],
              onSegmentTap: onSegmentTap,
              center: hasData
                  ? FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            leadLabel,
                            style: TextStyle(
                              color: summaryInk.withValues(alpha: .7),
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            _pct(leadValue),
                            style: const TextStyle(
                              color: summaryInk,
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Text(
                      '-',
                      style: TextStyle(color: summaryInk.withValues(alpha: .6)),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          _LegendDot(
            _palette[0],
            '$labelA ${_pct(a)}',
            onTapUp: onSegmentTap == null
                ? null
                : (d) => onSegmentTap!(0, d.globalPosition),
          ),
          const SizedBox(height: 2),
          _LegendDot(
            _palette[1],
            '$labelB ${_pct(b)}',
            onTapUp: onSegmentTap == null
                ? null
                : (d) => onSegmentTap!(1, d.globalPosition),
          ),
        ],
      ),
    );
  }
}

// 예매처 도넛 + 오른쪽 범례
class _SitesDonut extends StatelessWidget {
  const _SitesDonut({required this.sites});

  final List<Map<String, dynamic>> sites;

  @override
  Widget build(BuildContext context) {
    if (sites.isEmpty) return const _Empty();
    final top = sites.first;
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: _Donut(
            values: [for (final s in sites) _int(s['count']).toDouble()],
            colors: [
              for (final s in sites) _ticketingBrandColor('${s['name']}'),
            ],
            center: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${top['name']}',
                    style: TextStyle(
                      color: summaryInk.withValues(alpha: .7),
                      fontSize: 11,
                    ),
                  ),
                  Text(
                    _pct(top['percent']),
                    style: const TextStyle(
                      color: summaryInk,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 6,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (var i = 0; i < sites.length; i++)
                Row(
                  children: [
                    Expanded(
                      child: _LegendDot(
                        _ticketingBrandColor('${sites[i]['name']}'),
                        '${sites[i]['name']}',
                      ),
                    ),
                    Text(
                      '${_pct(sites[i]['percent'])}  ${_int(sites[i]['count'])}장',
                      style: const TextStyle(
                        color: summaryInk,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- 막대 ----

// 세로 막대 그래프. 주어진 높이에 맞춰 막대 높이를 정하고, 막대가 8개를 넘으면 가로로 스크롤
class _Bars extends StatelessWidget {
  const _Bars({
    required this.values,
    required this.labels,
    required this.color,
    this.format,
    this.scroll = true,
    this.maxValue,
    this.onBarTap,
  });

  final List<int> values;
  final List<String> labels;
  final Color color;
  final String Function(int)? format;

  // 막대가 8개를 넘으면 가로로 스크롤, false면 항상 폭에 맞춰 나눔(연도별 12개월 차트)
  final bool scroll;

  // 연도별 차트끼리 높이를 비교할 수 있게 같은 최댓값을 쓸 때 지정
  final int? maxValue;

  // 막대를 눌렀을 때 몇 번째 막대인지와 화면 좌표를 알려줌
  final void Function(int index, Offset globalPosition)? onBarTap;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const _Empty();
    final maxV = maxValue ?? values.reduce((a, b) => a > b ? a : b);
    return LayoutBuilder(
      builder: (context, box) {
        // 값 글자(위)와 월 라벨(아래) 자리를 뺀 만큼이 막대 최대 높이
        final chartH = math.max(20.0, box.maxHeight - 38);
        final bars = Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < values.length; i++)
              SizedBox(
                width: scroll && values.length > 8 ? 40 : null,
                child: _bar(i, maxV, chartH, box.maxHeight),
              ),
          ],
        );
        final chart = scroll && values.length > 8
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: bars,
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < values.length; i++)
                    Expanded(child: _bar(i, maxV, chartH, box.maxHeight)),
                ],
              );
        return SizedBox(height: box.maxHeight, child: chart);
      },
    );
  }

  Widget _bar(int index, int maxV, double chartH, double fullHeight) {
    final v = values[index];
    final label = labels[index];
    final h = maxV == 0 ? 0.0 : chartH * v / maxV;
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 폭이 좁아도 값 글자가 두 줄로 꺾여 높이가 늘지 않게 한 줄로 줄여 맞춤
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            v == 0 ? '' : (format?.call(v) ?? '$v'),
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(color: summaryInk, fontSize: 11),
          ),
        ),
        const SizedBox(height: 2),
        Container(
          height: v == 0 ? 2 : h.clamp(3.0, chartH),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: v == 0 ? summaryInk.withValues(alpha: .2) : color,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              color: summaryInk.withValues(alpha: .75),
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
    // 막대가 낮아도 그 달 영역 어디를 눌러도 반응하도록 차트 전체 높이를 터치 영역으로 씀
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: onBarTap == null
          ? null
          : (d) => onBarTap!(index, d.globalPosition),
      child: SizedBox(
        height: fullHeight,
        child: Align(alignment: Alignment.bottomCenter, child: column),
      ),
    );
  }
}

// 가로 막대 순위 목록: (이름, 값, 오른쪽에 보일 글자). 주어진 높이에 행을 고르게 펼침
class _HBars extends StatelessWidget {
  const _HBars({
    required this.items,
    this.colors,
    this.labelWidth = 96,
    this.centerLabel = false,
    this.highlightMax = false,
    this.maxValue,
  });

  final List<(String, int, String)> items;
  final List<Color>? colors;

  // 이름이 짧을 때(요일 등) 그래프와 떨어지지 않게 폭을 줄이고 가운데 정렬
  final double labelWidth;
  final bool centerLabel;

  // 가장 큰 값만 진한 색으로 강조
  final bool highlightMax;
  final int? maxValue;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _Empty();
    final maxV = maxValue ?? items.map((e) => e.$2).reduce(math.max);
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: constraints.maxHeight,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final item in items)
                Row(
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: Text(
                        item.$1,
                        textAlign: centerLabel
                            ? TextAlign.center
                            : TextAlign.start,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: summaryInk, fontSize: 12),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (_, c) => Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: maxV == 0
                                ? 2
                                : (c.maxWidth * item.$2 / maxV).clamp(
                                    2.0,
                                    c.maxWidth,
                                  ),
                            height: 14,
                            decoration: BoxDecoration(
                              color: colors == null
                                  ? (highlightMax && item.$2 != maxV
                                        ? _accent2
                                        : _accent)
                                  : colors![items.indexOf(item) %
                                        colors!.length],
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      item.$3,
                      style: const TextStyle(
                        color: summaryInk,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// 카드 제목 오른쪽 끝에 붙는 연도 칩 줄(해가 많으면 가로로 밀어서 봄)
class _YearChips extends StatelessWidget {
  const _YearChips({
    required this.years,
    required this.selected,
    required this.onSelected,
  });

  final List<String> years;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final year in years)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ChoiceChip(
                  label: Text(year, style: const TextStyle(fontSize: 12)),
                  selected: selected == year,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 0),
                  onSelected: (_) => onSelected(year),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// 연도 칩으로 한 해씩 골라 보는 1~12월 막대 차트(높이 비교를 위해 모든 연도가 같은 최댓값을 씀)
class _YearTabbedBars extends StatefulWidget {
  const _YearTabbedBars({
    required this.title,
    required this.byYear,
    required this.color,
    required this.maxValue,
    required this.selection,
    required this.selectionKey,
    this.format,
    this.onBarTap,
  });

  final String title;
  final Map<String, List<int>> byYear;
  final Color color;
  final int maxValue;
  final String Function(int)? format;

  // 선택한 연도를 화면 State의 맵에 기록해 두고, 다시 만들어질 때 거기서 복원
  final Map<String, String> selection;
  final String selectionKey;

  // (선택한 연도, 0부터 시작하는 월 번호, 화면 좌표)
  final void Function(String year, int monthIndex, Offset globalPosition)?
  onBarTap;

  @override
  State<_YearTabbedBars> createState() => _YearTabbedBarsState();
}

class _YearTabbedBarsState extends State<_YearTabbedBars> {
  late final List<String> _years = widget.byYear.keys.toList()..sort();
  late String _selected = _restore();

  String _restore() {
    final saved = widget.selection[widget.selectionKey];
    return saved != null && _years.contains(saved) ? saved : _years.last;
  }

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      title: widget.title,
      trailing: _YearChips(
        years: _years,
        selected: _selected,
        onSelected: (year) {
          widget.selection[widget.selectionKey] = year;
          setState(() => _selected = year);
        },
      ),
      child: _Bars(
        values: widget.byYear[_selected]!,
        labels: [for (var m = 1; m <= 12; m++) '$m'],
        color: widget.color,
        format: widget.format,
        scroll: false,
        maxValue: widget.maxValue,
        onBarTap: widget.onBarTap == null
            ? null
            : (i, pos) => widget.onBarTap!(_selected, i, pos),
      ),
    );
  }
}

// 처음 본 아티스트 이름표(많으면 위아래로 스크롤)
class _NewArtists extends StatefulWidget {
  const _NewArtists({required this.names});

  final List<String> names;

  @override
  State<_NewArtists> createState() => _NewArtistsState();
}

class _NewArtistsState extends State<_NewArtists> {
  int _page = 0;
  @override
  Widget build(BuildContext context) {
    final names = widget.names;
    if (names.isEmpty) return const _Empty();
    final count = (names.length / 4).ceil();
    final page = _page.clamp(0, count - 1);
    return Column(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final name in names.skip(page * 4).take(4))
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: _accent2,
                          ),
                        ),
                        Container(width: 20, height: 2, color: _accent2),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              color: summaryInk,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (count > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: page > 0
                    ? () => setState(() => _page = page - 1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${page + 1} / $count'),
              IconButton(
                onPressed: page < count - 1
                    ? () => setState(() => _page = page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: summaryInk,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// 현재 기간을 보여주고 누르면 다음 기간으로 넘어가는 알약 버튼
class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: active ? summaryInk : summaryPaper,
    borderRadius: BorderRadius.circular(18),
    elevation: 3,
    shadowColor: Colors.black.withValues(alpha: .22),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.swap_horiz_rounded,
              size: 18,
              color: active ? summaryPaper : summaryInk,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: active ? summaryPaper : summaryInk,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PeriodButton extends StatelessWidget {
  const _PeriodButton({
    required this.label,
    required this.onTap,
    this.loading = false,
  });

  final String label;
  final VoidCallback onTap;

  // 새 값을 불러오는 중이면 아이콘 대신 작은 로딩 표시
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: summaryInk,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: summaryPaper,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 4),
              loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: summaryPaper,
                      ),
                    )
                  : const Icon(Icons.autorenew, size: 14, color: summaryPaper),
            ],
          ),
        ),
      ),
    );
  }
}

// 연도 칩으로 고르는 "그 해에 처음 본 아티스트" (가장 최근 해가 기본 선택)
class _YearNewArtists extends StatefulWidget {
  const _YearNewArtists({required this.byYear, required this.selection});

  final Map<int, List<String>> byYear;

  // 선택한 연도를 화면 State의 맵에 기록해 두고, 다시 만들어질 때 거기서 복원
  final Map<String, String> selection;

  static const selectionKey = 'new_artists';

  @override
  State<_YearNewArtists> createState() => _YearNewArtistsState();
}

class _YearNewArtistsState extends State<_YearNewArtists> {
  late final List<int> _years = widget.byYear.keys.toList()..sort();
  late int _selected = _restore();

  int _restore() {
    final saved = int.tryParse(
      widget.selection[_YearNewArtists.selectionKey] ?? '',
    );
    return saved != null && _years.contains(saved) ? saved : _years.last;
  }

  @override
  Widget build(BuildContext context) {
    final names = widget.byYear[_selected] ?? const <String>[];
    return _CardShell(
      title: '처음 본 아티스트',
      trailing: _YearChips(
        years: [for (final y in _years) '$y'],
        selected: '$_selected',
        onSelected: (year) {
          widget.selection[_YearNewArtists.selectionKey] = year;
          setState(() => _selected = int.parse(year));
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${names.length}명',
            style: TextStyle(
              color: summaryInk.withValues(alpha: .7),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: _NewArtists(names: names)),
        ],
      ),
    );
  }
}
