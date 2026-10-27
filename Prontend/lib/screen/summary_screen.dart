import '../services/sound_effect_service.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/summary_calendar.dart';
import '../widgets/summary_report.dart';
import '../services/api_client.dart';
import '../services/news_list_service.dart';
import '../services/news_card_identity.dart';
import '../services/favorites_store.dart';
import '../models/news_model.dart';
import '../services/ticket_refresh_bus.dart';
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
                : SummaryReport(
                    key: ValueKey(_shownPeriod),
                    data: data,
                    period: _shownPeriod,
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
      // [백엔드 수정] 가로모드 왼쪽 동반 패널 - 다른 탭과 동일, 색만 결산 크라프트지로 맞춤.
      landscapeCompanionPanel: DiaryLandscapeCoverPanel(
        pageColor: _pageColor,
        child: buildUpcomingTicketLandscapePanel(),
      ),
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
                  label: _calendarMode ? '캘린더' : '$_periodLabel 보고서',
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

List<Map<String, dynamic>> _list(dynamic value) =>
    (value as List? ?? const []).whereType<Map<String, dynamic>>().toList();

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
