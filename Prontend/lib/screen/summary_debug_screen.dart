import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/summary_region_map.dart' show summaryInk, summaryPaper;

// [임시] 새 결산 응답을 한눈에 보려는 디버그 화면. 결산탭 개편 전까지만 쓰고 지울 것.
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

Future<Map<String, dynamic>> _defaultLoader(String period) =>
    ApiClient.instance.get('/summary?period=$period');

class SummaryDebugScreen extends StatefulWidget {
  const SummaryDebugScreen({super.key, this.loader = _defaultLoader});

  final SummaryJsonLoader loader;

  @override
  State<SummaryDebugScreen> createState() => _SummaryDebugScreenState();
}

class _SummaryDebugScreenState extends State<SummaryDebugScreen> {
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

  // 연도 칩 선택(차트별). 페이지가 화면에서 사라졌다 다시 만들어져도 유지하려고 화면 State에 보관
  final Map<String, String> _yearSelection = {};

  @override
  void initState() {
    super.initState();
    _load();
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
    _noticeTimer?.cancel();
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
    // 새 값을 불러오는 동안은 이전 내용을 흐리게 두고 위에 얇은 진행 막대만 보여줌
    return Stack(
      children: [
        AnimatedOpacity(
          opacity: _loading ? 0.45 : 1,
          duration: const Duration(milliseconds: 150),
          child: _Body(
            data: data,
            period: _shownPeriod,
            initialPage: _page,
            onPageChanged: (i) => _page = i,
            yearSelection: _yearSelection,
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
      pageTextureEnabled: false,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.summary),
      child: Material(
        color: _pageColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: summaryInk),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const Text(
                    '[임시] 결산 디버그',
                    style: TextStyle(
                      color: summaryInk,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  _PeriodButton(
                    label: _periodLabel,
                    loading: _loading && _data != null,
                    onTap: _nextPeriod,
                  ),
                ],
              ),
              Expanded(child: _content()),
            ],
          ),
        ),
      ),
    );
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
    required this.data,
    required this.period,
    required this.initialPage,
    required this.onPageChanged,
    required this.yearSelection,
  });

  final Map<String, dynamic> data;
  final String period;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final Map<String, String> yearSelection;

  @override
  Widget build(BuildContext context) {
    final monthly = _list(data['monthly_stats']);
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

    String monthLabel(Map<String, dynamic> m) {
      final parts = (m['month'] as String? ?? '').split('-');
      if (parts.length != 2) return '';
      return parts[1] == '01'
          ? "${parts[0].substring(2)}.${parts[1]}"
          : parts[1];
    }

    // 전체 기간은 연도 탭으로 골라 1~12월 차트를 보고, 6개월/1년은 이어서 한 차트로 그림
    Widget monthChart(String key, Color color, {String Function(int)? format}) {
      if (period != 'all') {
        return _Bars(
          values: [for (final m in monthly) _int(m[key])],
          labels: [for (final m in monthly) monthLabel(m)],
          color: color,
          format: format,
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
        byYear: byYear,
        color: color,
        format: format,
        maxValue: yearMax,
        selection: yearSelection,
        selectionKey: 'month_$key',
      );
    }

    final weekdayMax = weekdays.isEmpty
        ? 0
        : weekdays.reduce((a, b) => a > b ? a : b);

    final summaryTiles = <Widget>[
      _Tile('관람', '${_int(data['concert_count'])}회'),
      _Tile('총 지출', _won(_int(data['total_spent']))),
      _Tile(
        '평균 티켓값',
        data['avg_ticket_price'] == null
            ? '-'
            : _won((_int(data['avg_ticket_price']) ~/ 1000) * 1000),
      ),
      _Tile('가장 많이 본 장르', genres.isEmpty ? '-' : genres.join(', ')),
      _Tile(
        '총 관람 시간',
        _hours(_int(data['total_runtime_minutes'])),
        sub: '시간 모름 ${_int(data['runtime_missing_count'])}장',
      ),
      _Tile(
        '들은 곡',
        '${_int(data['song_count'])}곡',
        sub: '+ 어림 ${_int(data['song_count_estimated'])}곡',
      ),
      _Tile(
        '사진 / 일기',
        '${_int(data['photo_count'])}장 / ${_int(data['diary_count'])}개',
      ),
      _Tile(
        '한 달 최다',
        busiest == null ? '-' : '${busiest['count']}회',
        sub: busiest == null ? null : '${busiest['month']}',
      ),
    ];

    // 기록 타일은 값이 있는 것만 보여주고(없으면 카드째 숨김), 개수에 맞춰 격자를 정함
    final recordTiles = <Widget>[
      if (maxSpend != null)
        _Tile(
          '최고 지출',
          _won(_int(maxSpend['price'])),
          sub: '${maxSpend['concert_name']}',
        ),
      if (topSpendArtist != null)
        _Tile(
          '가장 많이 쓴 아티스트',
          '${topSpendArtist['name']}',
          sub: _won(_int(topSpendArtist['amount'])),
        ),
      if (heard != null)
        _Tile(
          '가장 많이 들은 곡',
          '${heard['name']}',
          sub: '${heard['artist'] ?? ''} · ${heard['count']}번',
        ),
      if (rare != null)
        _Tile(
          '가장 희귀한 곡',
          '${rare['name']}',
          sub:
              '${rare['concert_name']} · 예상 ${_pct((rare['probability'] as num) * 100)}',
        ),
    ];

    final pages = <Widget>[
      // 1페이지: 요약 / 기록 / 선호 비율(도넛 3개)
      _PageOfCards(
        cards: [
          _CardSpec(
            title: '요약',
            flex: 3,
            minHeight: 250,
            child: _TileGrid(tiles: summaryTiles),
          ),
          if (recordTiles.isNotEmpty)
            _CardSpec(
              title: '기록',
              flex: 3,
              minHeight: recordTiles.length > 2 ? 190 : 120,
              child: _TileGrid(
                columns: recordTiles.length == 4 ? 2 : recordTiles.length,
                tiles: recordTiles,
              ),
            ),
          _CardSpec(
            title: '선호 비율',
            flex: 4,
            minHeight: 210,
            child: Row(
              children: [
                Expanded(
                  child: _DonutBlock(
                    '스탠딩',
                    data['standing_percent'],
                    '좌석',
                    data['seated_percent'],
                  ),
                ),
                Expanded(
                  child: _DonutBlock(
                    '첫콘',
                    data['first_day_percent'],
                    '막콘',
                    data['last_day_percent'],
                  ),
                ),
                Expanded(
                  child: _DonutBlock(
                    '국내',
                    data['origin_domestic_percent'],
                    '내한',
                    data['origin_foreign_percent'],
                    note: '미분류 ${_int(data['origin_unknown_count'])}장',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      // 2페이지: 월별 관람 / 월별 지출 / 요일별
      _PageOfCards(
        cards: [
          _CardSpec(
            title: '월별 관람 수',
            flex: 3,
            minHeight: 230,
            child: monthChart('concert_count', _accent),
          ),
          _CardSpec(
            title: '월별 지출',
            flex: 3,
            minHeight: 230,
            child: monthChart('spent', _accent2, format: _manwon),
          ),
          _CardSpec(
            title: '요일별 공연 수',
            flex: 3,
            minHeight: 230,
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
      // 3페이지: 예매처 / 공연장 / 관람 아티스트 / 처음 본 아티스트
      _PageOfCards(
        cards: [
          _CardSpec(
            title: '예매처 비중',
            note: '예매처 모름 ${_int(data['ticketing_site_unknown_count'])}장 제외',
            flex: 3,
            minHeight: 190,
            child: _SitesDonut(sites: sites),
          ),
          _CardSpec(
            title: '가장 많이 간 공연장',
            flex: 2,
            minHeight: 130,
            child: _HBars(
              items: [
                for (final v in venues)
                  ('${v['name']}', _int(v['count']), '${_int(v['count'])}회'),
              ],
            ),
          ),
          _CardSpec(
            title: '관람 아티스트',
            flex: 3,
            minHeight: 200,
            child: _HBars(
              items: [
                for (final a in artists)
                  ('${a['name']}', _int(a['count']), '${_int(a['count'])}회'),
              ],
            ),
          ),
          // 전체 기간은 모두가 "처음"이라 의미가 없어서, 처음 본 해별로 나눠 보여줌
          if (period == 'all' && newArtistsByYear.isNotEmpty)
            _CardSpec(
              title: '해마다 처음 본 아티스트',
              flex: 3,
              minHeight: 150,
              child: _YearNewArtists(
                byYear: newArtistsByYear,
                selection: yearSelection,
              ),
            )
          else
            _CardSpec(
              title: '처음 본 아티스트 ${_int(data['new_artist_count'])}명',
              flex: 3,
              minHeight: 130,
              child: _NewArtists(names: newArtists),
            ),
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
              for (var i = 0; i < _count; i++)
                GestureDetector(
                  onTap: () => _goTo(i),
                  child: Container(
                    width: i == _page ? 18 : 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: i == _page
                          ? summaryInk
                          : summaryInk.withValues(alpha: .3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
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
    this.note,
  });

  final String title;
  final String? note;
  final Widget child;

  // 페이지 높이가 충분하면 flex 비율로 남는 공간을 나눠 채우고, 모자라면 minHeight로 스크롤
  final int flex;
  final double minHeight;
}

class _PageOfCards extends StatelessWidget {
  const _PageOfCards({required this.cards});

  final List<_CardSpec> cards;

  @override
  Widget build(BuildContext context) {
    const gap = 10.0;
    return LayoutBuilder(
      builder: (context, box) {
        final need =
            cards.fold<double>(0, (sum, c) => sum + c.minHeight) +
            gap * (cards.length - 1) +
            8;
        if (box.maxHeight >= need) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
            child: Column(
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(height: gap),
                  Expanded(
                    flex: cards[i].flex,
                    child: _Card(spec: cards[i]),
                  ),
                ],
              ],
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
          children: [
            for (final c in cards)
              Padding(
                padding: const EdgeInsets.only(bottom: gap),
                child: SizedBox(
                  height: c.minHeight,
                  child: _Card(spec: c),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.spec});

  final _CardSpec spec;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: summaryPaper,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: summaryInk.withValues(alpha: .28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            spec.title,
            style: const TextStyle(
              color: summaryInk,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          if (spec.note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                spec.note!,
                style: TextStyle(
                  color: summaryInk.withValues(alpha: .6),
                  fontSize: 11,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(child: spec.child),
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

// ---- 숫자 타일 ----

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, {this.sub});

  final String label;
  final String value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .35),
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
              color: summaryInk.withValues(alpha: .7),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 2),
          // 타일이 낮아도 넘치지 않게 값/보조 글자가 남는 높이 안에서 줄어듦
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: const TextStyle(
                  color: summaryInk,
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                ),
              ),
            ),
          ),
          if (sub != null)
            Flexible(
              child: Text(
                sub!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: summaryInk.withValues(alpha: .6),
                  fontSize: 10,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// 타일들을 주어진 높이를 꽉 채우는 격자로 배치(폭이 좁으면 2열)
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.tiles, this.columns});

  final List<Widget> tiles;
  final int? columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final cols = columns ?? (box.maxWidth >= 480 ? 4 : 2);
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
  const _Donut({required this.values, required this.center});

  final List<double> values;
  final Widget center;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = math.max(
          40.0,
          math.min(box.maxWidth, box.maxHeight).toDouble(),
        );
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _DonutPainter(values, _palette),
              child: Padding(
                padding: EdgeInsets.all(size * 0.2),
                child: Center(child: center),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot(this.color, this.text);

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
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
  const _DonutBlock(this.labelA, this.a, this.labelB, this.b, {this.note});

  final String labelA;
  final dynamic a;
  final String labelB;
  final dynamic b;
  final String? note;

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
          _LegendDot(_palette[0], '$labelA ${_pct(a)}'),
          const SizedBox(height: 2),
          _LegendDot(_palette[1], '$labelB ${_pct(b)}'),
          if (note != null)
            Text(
              note!,
              style: TextStyle(
                color: summaryInk.withValues(alpha: .55),
                fontSize: 10,
              ),
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
                        _palette[i % _palette.length],
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
  });

  final List<int> values;
  final List<String> labels;
  final Color color;
  final String Function(int)? format;

  // 막대가 8개를 넘으면 가로로 스크롤, false면 항상 폭에 맞춰 나눔(연도별 12개월 차트)
  final bool scroll;

  // 연도별 차트끼리 높이를 비교할 수 있게 같은 최댓값을 쓸 때 지정
  final int? maxValue;

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
                child: _bar(values[i], labels[i], maxV, chartH),
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
                    Expanded(child: _bar(values[i], labels[i], maxV, chartH)),
                ],
              );
        return SizedBox(height: box.maxHeight, child: chart);
      },
    );
  }

  Widget _bar(int v, String label, int maxV, double chartH) {
    final h = maxV == 0 ? 0.0 : chartH * v / maxV;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 폭이 좁아도 값 글자가 두 줄로 꺾여 높이가 늘지 않게 한 줄로 줄여 맞춤
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            v == 0 ? '' : (format?.call(v) ?? '$v'),
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(color: summaryInk, fontSize: 10),
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
        Text(
          label,
          style: TextStyle(
            color: summaryInk.withValues(alpha: .75),
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}

// 가로 막대 순위 목록: (이름, 값, 오른쪽에 보일 글자). 주어진 높이에 행을 고르게 펼침
class _HBars extends StatelessWidget {
  const _HBars({
    required this.items,
    this.labelWidth = 96,
    this.centerLabel = false,
    this.highlightMax = false,
    this.maxValue,
  });

  final List<(String, int, String)> items;

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
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final item in items)
          Row(
            children: [
              SizedBox(
                width: labelWidth,
                child: Text(
                  item.$1,
                  textAlign: centerLabel ? TextAlign.center : TextAlign.start,
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
                        color: highlightMax && item.$2 != maxV
                            ? _accent2
                            : _accent,
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
    );
  }
}

// 연도 칩으로 한 해씩 골라 보는 1~12월 막대 차트(높이 비교를 위해 모든 연도가 같은 최댓값을 씀)
class _YearTabbedBars extends StatefulWidget {
  const _YearTabbedBars({
    required this.byYear,
    required this.color,
    required this.maxValue,
    required this.selection,
    required this.selectionKey,
    this.format,
  });

  final Map<String, List<int>> byYear;
  final Color color;
  final int maxValue;
  final String Function(int)? format;

  // 선택한 연도를 화면 State의 맵에 기록해 두고, 다시 만들어질 때 거기서 복원
  final Map<String, String> selection;
  final String selectionKey;

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final year in _years)
              ChoiceChip(
                label: Text(year),
                selected: _selected == year,
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  widget.selection[widget.selectionKey] = year;
                  setState(() => _selected = year);
                },
              ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _Bars(
            values: widget.byYear[_selected]!,
            labels: [for (var m = 1; m <= 12; m++) '$m'],
            color: widget.color,
            format: widget.format,
            scroll: false,
            maxValue: widget.maxValue,
          ),
        ),
      ],
    );
  }
}

// 처음 본 아티스트 이름표(많으면 일부만 보이고 나머지는 +N명)
class _NewArtists extends StatelessWidget {
  const _NewArtists({required this.names});

  final List<String> names;

  static const _limit = 12;

  @override
  Widget build(BuildContext context) {
    if (names.isEmpty) return const _Empty();
    final shown = names.take(_limit).toList();
    final rest = names.length - shown.length;
    return ClipRect(
      child: Align(
        alignment: Alignment.topLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final n in shown) _Pill(n),
            if (rest > 0) _Pill('+$rest명', filled: true),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.filled = false});

  final String text;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: filled ? summaryInk : Colors.white.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: filled ? summaryPaper : summaryInk,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// 현재 기간을 보여주고 누르면 다음 기간으로 넘어가는 알약 버튼
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final year in _years)
              ChoiceChip(
                label: Text('$year'),
                selected: _selected == year,
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  widget.selection[_YearNewArtists.selectionKey] = '$year';
                  setState(() => _selected = year);
                },
              ),
          ],
        ),
        const SizedBox(height: 6),
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
    );
  }
}
