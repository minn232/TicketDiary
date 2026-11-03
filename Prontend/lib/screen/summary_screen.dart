import '../widgets/app_back_handler.dart';
import '../services/sound_effect_service.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/summary_calendar.dart';
import '../widgets/summary_report.dart';
import '../widgets/scrapbook_page_background.dart';
import '../services/api_client.dart';
import '../services/news_list_service.dart';
import '../services/news_card_identity.dart';
import '../services/favorites_store.dart';
import '../models/news_model.dart';
import '../services/ticket_refresh_bus.dart';
import '../services/ticket_service.dart';
import 'diary_screen.dart' show buildUpcomingTicketLandscapePanel;
import '../widgets/diary_landscape_cover_panel.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/tab_nav_coordinator.dart';
import '../widgets/summary_region_map.dart' show summaryInk, summaryPaper;

// 결산 탭: 관람 기록과 기간별 통계를 표시합니다.
// 값은 `GET /summary` 원본 JSON을 그대로 읽음(SummaryModel 미사용).
typedef SummaryJsonLoader =
    Future<Map<String, dynamic>> Function(String period);

const _pageColor = Color(0xFFCEB99B);
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
  // 기간별로 받아둔 값. 보고서는 지금 고른 기간의 값으로만 그림 - 예전엔 새 기간을
  // 불러오는 동안 다른 기간(캘린더의 전체 기간) 숫자를 보여줬다가 바뀌어 보였음
  final Map<String, Map<String, dynamic>> _cache = {};
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

  // [백엔드 수정] 오늘 날짜 버튼을 누를 때마다 올려 캘린더를 오늘로 돌림
  final _calendarTodayRequest = ValueNotifier<int>(0);

  // 연도 칩 선택(차트별). 페이지가 화면에서 사라졌다 다시 만들어져도 유지하려고 화면 State에 보관
  final Map<String, String> _yearSelection = {};
  late Future<List<NewsModel>> _newsFuture;

  // [백엔드 수정] 결산 API는 관람 끝난 티켓만 줘서, 아직 안 간 내 티켓은 티켓 목록에서 따로 채움.
  List<Map<String, dynamic>> _upcomingTickets = const [];
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
    _loadUpcomingTickets();
    TicketRefreshBus.tick.addListener(_loadUpcomingTickets);
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

  // [백엔드 수정] 관람일(없으면 공연 첫날)에 'myTicket'으로 표시 - 연 모아보기·관람 횟수엔 안 셈.
  Future<void> _loadUpcomingTickets() async {
    try {
      final tickets = await TicketService().listTickets();
      if (!mounted) return;
      setState(() {
        _upcomingTickets = [
          for (final t in tickets)
            if (t.status != 'after_concert')
              if ((t.attendedDate ?? t.concert?.startDate) case final date?)
                {
                  'kind': 'myTicket',
                  'ticket_id': t.id,
                  'concert_name': t.concert?.name ?? '',
                  'poster_url': t.concert?.posterUrl,
                  'date': DateUtils.dateOnly(date.toLocal()).toIso8601String(),
                  'price': t.price,
                },
        ];
      });
    } catch (_) {
      // 못 불러오면 관람 기록·소식 일정만 보여줌
    }
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
      if (!mounted) return;
      // 늦게 온 이전 응답도 그 기간 값으로는 맞으니 보관만 하고 화면엔 반영 안 함
      _cache[period] = data;
      if (id != _requestId) return;
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
    TicketRefreshBus.tick.removeListener(_loadUpcomingTickets);
    FavoritesStore.instance.removeListener(_refreshCalendarNews);
    _calendarSelection.dispose();
    _calendarTodayRequest.dispose();
    _noticeTimer?.cancel();
    super.dispose();
  }

  String get _periodLabel =>
      _periods.entries.firstWhere((e) => e.value == _period).key;

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
    final calendarData = _cache['all'] ?? data;
    final reportData = _cache[_period];
    // 보고서: 고른 기간 값이 있으면 바로(새로고침은 위 진행 막대로만), 없으면 뼈대
    return Stack(
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: FutureBuilder<List<NewsModel>>(
            key: ValueKey(
              _calendarMode
                  ? 'calendar'
                  : reportData == null
                  ? 'skeleton'
                  : 'report-$_period',
            ),
            future: _newsFuture,
            builder: (context, newsSnapshot) => _calendarMode
                ? SummaryCalendar(
                    tickets: [
                      ..._list(calendarData['ticket_details']),
                      ..._upcomingTickets,
                    ],
                    news: newsSnapshot.data ?? const [],
                    selection: _calendarSelection,
                    todayRequest: _calendarTodayRequest,
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
                : reportData == null
                ? const SummaryReportSkeleton()
                : SummaryReport(
                    key: ValueKey(_period),
                    data: reportData,
                    period: _period,
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
  Widget build(BuildContext context) => AppBackHandler(
    canHandle: () => !_calendarMode,
    onBack: () => setState(() {
      _calendarMode = true;
      _page = 0;
    }),
    child: _buildFrame(context),
  );

  Widget _buildFrame(BuildContext context) {
    // 실제 결산탭처럼 일기 프레임 안에 그림(옆 인덱스 탭은 결산 탭 활성)
    return DiaryPageFrame(
      isTabRoot: true,
      pageTextureEnabled: false,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.summary),
      // [백엔드 수정] 가로모드 왼쪽 동반 패널 - 다른 탭과 동일, 색만 결산 크라프트지로 맞춤.
      landscapeCompanionPanel: DiaryLandscapeCoverPanel(
        pageColor: _pageColor,
        child: buildUpcomingTicketLandscapePanel(),
      ),
      child: Material(
        color: _pageColor,
        // 다른 탭과 같은 종이 질감 - 프레임 옵션(pageTextureEnabled)은 내용 위를 덮어
        // 포스터/카드까지 흐려지므로 결산은 내용 뒤에 깖
        child: Stack(
          children: [
            const Positioned.fill(
              child: ScrapbookPaperTextureOverlay(opacity: .75, seed: 110),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _ModeButton(
                          label: _calendarMode ? '캘린더' : '보고서',
                          cornerRadius: 6,
                          active: true,
                          onTap: () {
                            _playSwitchSound();
                            setState(() {
                              _calendarMode = !_calendarMode;
                              _page = 0;
                              if (!_calendarMode) _period = '6m';
                            });
                            if (!_calendarMode) _load();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ModeButton(
                          label: _calendarMode ? _todayLabel : _periodLabel,
                          showArrow: false,
                          active: !_calendarMode,
                          onTap: _calendarMode
                              ? () => _calendarTodayRequest.value++
                              : _advancePeriod,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(child: _content()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _todayLabel {
    final today = DateTime.now();
    return '${today.year}.${today.month.toString().padLeft(2, '0')}.${today.day.toString().padLeft(2, '0')}';
  }

  void _playSwitchSound() {
    unawaited(SoundEffectService.instance.play(SoundEffect.bookSip));
  }

  void _advancePeriod() {
    _playSwitchSound();
    setState(() {
      _period = switch (_period) {
        '6m' => '1y',
        '1y' => 'all',
        _ => '6m',
      };
      _page = 0;
    });
    _load();
  }
}

List<Map<String, dynamic>> _list(dynamic value) =>
    (value as List? ?? const []).whereType<Map<String, dynamic>>().toList();

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.active,
    required this.onTap,
    this.showArrow = true,
    this.cornerRadius = 18,
  });
  final bool showArrow;
  final double cornerRadius;
  final String label;
  final bool active;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: active ? summaryInk : summaryInk.withValues(alpha: .08),
    borderRadius: BorderRadius.circular(cornerRadius),
    elevation: active ? 3 : 0,
    shadowColor: Colors.black.withValues(alpha: .22),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(cornerRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: active && showArrow ? 23 : 0,
              ),
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active
                        ? summaryPaper
                        : summaryInk.withValues(alpha: .45),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            if (active && showArrow)
              const Positioned(
                left: 0,
                child: Icon(
                  Icons.swap_horiz_rounded,
                  size: 18,
                  color: summaryPaper,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
