import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/services/api_client.dart';
import 'package:ticketdiary/services/favorites_store.dart';
import 'package:ticketdiary/services/news_cache_store.dart';
import 'package:ticketdiary/services/social_service.dart';
import 'package:ticketdiary/widgets/carousel_slide_transition.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/news_pull_tab.dart';
import 'package:ticketdiary/widgets/poster_background.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';
import 'package:ticketdiary/widgets/pressable_scale.dart';
import 'package:ticketdiary/widgets/responsive_text.dart';

import 'favorite_pinned_settings_screen.dart';
import 'news_detail_overlay.dart';

// =============================================================================
// [소식 탭] 카드 두 소스를 같은 형식(_PolaroidCard)으로 합쳐서 보여줍니다.
// 1. 찜한 공연 — 백엔드 매칭 없이, 순수 로컬 찜 목록(FavoritesStore)을 그대로
//    카드로 만듭니다(NewsModel.fromFavoritedConcert). 그래서 항상 "찜한 그
//    공연"만 정확히 나타납니다.
// 2. 백엔드 `GET /social/feed` — "서버에 저장된 아티스트 팔로우 목록" 기준으로
//    생성되므로, 조회 전에 로컬 찜 아티스트 목록을 서버에 동기화합니다.
// =============================================================================

class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key});

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

/// 소식 페이지 ↔ 찜/아티스트 패널을 오가는 "페이지 조각(풀탭)" 전환 단계.
/// 전환은 액자 창 안에서 아래 페이지만 가로로 밀려 넘어가는 캐러셀 방식.
///
/// - [news]: 소식 그리드만 보임(풀탭은 왼쪽 끝).
/// - [toFav]: 풀탭이 오른쪽으로 이동하며 소식 페이지가 오른쪽으로 밀려나가고
///   왼쪽부터 찜 패널이 들어옴.
/// - [fav]: 찜/아티스트 패널만 보임(풀탭은 오른쪽 끝).
/// - [loading]: 풀탭을 다시 눌러 최신 소식을 준비하는 동안. 전환은 멈추고
///   로딩 표시는 풀탭 하트의 시계방향 쐐기 회전이 대신함.
/// - [toNews]: 최신 소식이 준비되면 풀탭이 왼쪽으로 돌아오며 찜 패널이
///   왼쪽으로 나가고 오른쪽에서 소식 페이지가 들어옴.
enum _FlipPhase { news, toFav, fav, loading, toNews }

class _NewsScreenState extends State<NewsScreen> with TickerProviderStateMixin {
  static const Color _paperColor = Color(0xFFF4F1E1);

  /// 소식 페이지 상단 여백을 기본(10)보다 늘려, 페이지 뒤에서 끼워 올린
  /// 풀탭 손잡이가 상단 경계선 위로 삐져나올 공간을 만듭니다.
  static const double _pageTop = 40;

  late Future<List<NewsModel>> _newsFuture;

  final SocialService _socialService = SocialService();

  /// 카드 확장 애니메이션의 시작 Rect를 구하기 위한, 카드 인덱스별 key.
  final List<GlobalKey> _cardKeys = [];

  // ─── 풀탭 전환 상태 ───────────────────────────────────────────────
  /// 풀탭 위치이자 체커보드 진행도의 원천. 0.0=소식/왼쪽, 1.0=찜/오른쪽.
  late final AnimationController _slide;

  /// 로딩 중 풀탭 하트에 보여주는 시계방향 쐐기 반복 애니메이션(한 바퀴가
  /// "사라짐 절반 + 나타남 절반"). 로딩이 아닐 때는 그냥 0에서 멈춰 있어
  /// 하트가 평소처럼 온전히 보입니다.
  late final AnimationController _heartWipe;

  /// 소식 로딩 중 "유리에 강한 빛 반사가 껴서 내용이 안 보이는" 백색 글레어
  /// 오버레이의 페이드. 0.0=글레어가 꽉 차 하얗게 가림(로딩 중), 1.0=글레어가
  /// 완전히 걷혀 카드가 보임. 로딩이 끝나면 0→1로 부드럽게 걷습니다.
  late final AnimationController _glassReveal;

  _FlipPhase _phase = _FlipPhase.news;

  /// 찜 패널은 전환/로딩 여러 단계에 걸쳐 살아 있어야(검색어·찜 토글 유지)
  /// 하므로, 같은 GlobalKey로 만들어 트리 위치가 바뀌어도 State가 유지되게
  /// 합니다.
  final GlobalKey _favPanelKey = GlobalKey();

  /// 소식 본문(FutureBuilder)도 같은 이유로 GlobalKey를 씁니다 — 없으면
  /// toNews(체커보드 전환 안, AnimatedBuilder 아래)에서 news(바로 반환)로
  /// 단계가 바뀔 때 부모 트리 모양이 완전히 달라져 Flutter가 기존
  /// FutureBuilder를 재사용하지 못하고 새로 마운트합니다. 새로 마운트된
  /// FutureBuilder는 future가 이미 resolve된 상태여도 첫 프레임엔 항상
  /// "로딩 중"으로 시작해(다음 프레임에야 데이터로 갱신) — 소식으로 돌아온
  /// 직후 카드들이 아주 잠깐 사라졌다 나타나는 깜빡임의 원인이었습니다.
  final GlobalKey _newsBodyKey = GlobalKey();

  /// 복귀 시 최신 소식 로딩이 너무 오래 걸리면(백엔드 오류 등) 기존
  /// 데이터로라도 소식으로 되돌아오게 하는 안전 타임아웃.
  Timer? _returnTimeout;

  /// 최신 소식(또는 타임아웃 시 기존 데이터)이 준비됐는지. true가 되어도
  /// 곧바로 전환하지 않고, 지금 돌고 있는 하트 바퀴가 끝나 하트가 온전히
  /// 채워지는 순간([_onHeartWipeStatus])에 맞춰 전환합니다.
  bool _returnDataReady = false;
  Future<List<NewsModel>>? _returnReadyFuture;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    )..addStatusListener(_onSlideStatus);
    _heartWipe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..addStatusListener(_onHeartWipeStatus);
    // 0.0에서 시작 = 진입하자마자 유리가 하얗게 껴 있는 상태.
    _glassReveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    );

    // 화면 초기화 시 데이터 호출 시작. 진입 시 페이지 넘김은 이제 이
    // 로딩을 기다리지 않고 곧바로 이 화면을 드러내며, 로딩 중에는 아래
    // 소식 본문 위에 백색 유리 글레어를 씌웠다가 로딩이 끝나면 걷어냅니다.
    _newsFuture = _loadNewsWithCache();
    _armGlassReveal(_newsFuture);
  }

  @override
  void dispose() {
    _returnTimeout?.cancel();
    _slide.dispose();
    _heartWipe.dispose();
    _glassReveal.dispose();
    super.dispose();
  }

  /// [future] 조회가 진행되는 동안 유리 글레어를 꽉 채웠다가(값 0), 조회가
  /// 끝나면 부드럽게 걷어냅니다(0→1). 첫 진입과 "다시 시도"에서만 씁니다 —
  /// 백그라운드 갱신·찜 복귀는 각자의 방식이 있어 글레어를 다시 씌우지
  /// 않습니다.
  void _armGlassReveal(Future<List<NewsModel>> future) {
    _glassReveal.value = 0.0;
    unawaited(
      future.whenComplete(() {
        if (mounted) _glassReveal.forward();
      }),
    );
  }

  void _onSlideStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      // 오른쪽 끝 도착 → 찜 패널만 남김.
      if (_phase == _FlipPhase.toFav) {
        setState(() => _phase = _FlipPhase.fav);
      }
    } else if (status == AnimationStatus.dismissed) {
      // 왼쪽 끝 복귀 → 소식만 남김.
      if (_phase == _FlipPhase.toNews) {
        setState(() => _phase = _FlipPhase.news);
      }
    }
  }

  /// 하트 쐐기 바퀴가 한 번 끝날 때마다(=하트가 온전히 채워지는 순간)
  /// 불립니다. 최신 소식이 아직 준비 안 됐으면 곧바로 새 바퀴를 돌려
  /// 계속 로딩 표시를 이어가고, 준비됐으면 바로 이 "온전히 채워진" 순간에
  /// 맞춰 실제 전환을 시작합니다 — 애니메이션이 어중간한 채로 뚝 끊기지
  /// 않습니다.
  void _onHeartWipeStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted || _phase != _FlipPhase.loading) return;
    if (_returnDataReady) {
      _revealFreshNews(_returnReadyFuture!);
    } else {
      _heartWipe.forward(from: 0);
    }
  }

  /// 풀탭 조각을 눌렀을 때. 위치(단계)에 따라 앞으로 가거나 되돌아옵니다.
  void _onPullTab() {
    switch (_phase) {
      case _FlipPhase.news:
        setState(() => _phase = _FlipPhase.toFav);
        _slide.forward(from: 0);
      case _FlipPhase.fav:
        _startReturnToNews();
      case _FlipPhase.toFav:
      case _FlipPhase.toNews:
      case _FlipPhase.loading:
        // 전환/로딩 중엔 눌림 무시.
        break;
    }
  }

  /// 찜 패널에서 풀탭을 눌러 소식으로 되돌아가는 흐름의 시작.
  ///
  /// 찜 변경은 이미 [FavoritesStore]에 실시간 반영돼 있으므로, 여기서 그
  /// 변경을 기준으로 최신 소식을 새로 불러옵니다("적용"). 로딩되는 동안엔
  /// 전환을 멈추고 풀탭 하트를 시계방향 쐐기로 반복 회전시켜 로딩 중임을
  /// 보여주다가, 데이터가 준비되면(또는 타임아웃되면) 지금 돌고 있는
  /// 하트 바퀴가 끝나는 순간([_onHeartWipeStatus])에 맞춰 역체커보드로
  /// 최신 소식을 드러냅니다.
  void _startReturnToNews() {
    setState(() => _phase = _FlipPhase.loading);
    _returnDataReady = false;
    _returnReadyFuture = null;
    _heartWipe.forward(from: 0);

    void markReady(Future<List<NewsModel>> future) {
      if (!mounted || _returnDataReady) return;
      _returnDataReady = true;
      _returnReadyFuture = future;
      _returnTimeout?.cancel();
    }

    _returnTimeout?.cancel();
    _returnTimeout = Timer(const Duration(seconds: 10), () {
      // 타임아웃: 기존 데이터로라도 소식으로 복귀합니다.
      markReady(_newsFuture);
    });

    _fetchAndCacheNews()
        .then((items) => markReady(Future.value(items)))
        .catchError((Object e) => markReady(Future.error(e)));
  }

  void _revealFreshNews(Future<List<NewsModel>> future) {
    setState(() {
      _newsFuture = future;
      _phase = _FlipPhase.toNews;
    });
    _slide.reverse(from: 1); // 1 → 0: 풀탭이 왼쪽으로 돌아오며 역체커보드.
  }

  /// 캐시가 있으면 즉시 그걸로 화면을 채우고, 그 뒤 조용히 최신 데이터를
  /// 다시 불러와 캐시와 화면을 함께 갱신합니다("stale while revalidate").
  /// 캐시가 없으면(첫 방문 등) 기존처럼 네트워크 응답을 기다립니다.
  Future<List<NewsModel>> _loadNewsWithCache() async {
    // FavoritesStore.load()/syncFromServer()는 이미 로드/동기화됐으면 곧장
    // 반환하므로(멱등), 여기서 먼저 호출해도 안전합니다.
    // [백엔드 수정] syncFromServer() 호출 추가.
    await FavoritesStore.instance.load();
    await FavoritesStore.instance.syncFromServer();
    final cached = await NewsCacheStore.instance.load(
      favoritesRevision: FavoritesStore.instance.revision,
    );
    if (cached != null && cached.isNotEmpty) {
      unawaited(_refreshInBackground());
      return cached;
    }
    return _fetchAndCacheNews();
  }

  Future<void> _refreshInBackground() async {
    try {
      final fresh = await _fetchAndCacheNews();
      if (!mounted) return;
      setState(() => _newsFuture = Future.value(fresh));
    } catch (_) {
      // 백그라운드 갱신 실패는 조용히 무시합니다 — 캐시된 화면을 그대로 둡니다.
    }
  }

  Future<List<NewsModel>> _fetchAndCacheNews() async {
    final items = await _loadNews();
    unawaited(
      NewsCacheStore.instance.save(
        items,
        favoritesRevision: FavoritesStore.instance.revision,
      ),
    );
    return items;
  }

  Future<List<NewsModel>> _loadNews() async {
    // 백엔드 피드는 서버에 저장된 팔로우 목록 기준으로 생성되므로,
    // 로컬 찜 아티스트 목록을 먼저 서버에 동기화한 뒤 피드를 조회합니다.
    // [백엔드 수정] syncFromServer() 호출 추가.
    await FavoritesStore.instance.load();
    await FavoritesStore.instance.syncFromServer();
    final artistNames = FavoritesStore.instance.favoriteArtists
        .map((a) => a.name)
        .toList();
    try {
      await _socialService.syncArtistFollows(artistNames);
    } catch (_) {
      // 동기화에 실패해도(네트워크 순단 등) 기존 서버 팔로우 목록 기준의
      // 피드는 조회할 수 있으므로 계속 진행합니다.
    }

    final feed = await _socialService.getNewsFeed();

    // 백엔드는 한 번 생성된 소식을 아티스트 언팔로우 후에도 지우지 않고
    // 그대로 돌려주므로(GET /social/feed가 팔로우 상태와 무관하게 전체
    // 반환), 지금 실제로 팔로우 중인 아티스트의 소식만 화면에 남깁니다.
    List<NewsModel> filteredFeed;
    try {
      final entries = await _socialService.getArtistFollowEntries();
      final currentFollows = {
        for (final e in entries)
          if ((e['artist_name'] as String?)?.isNotEmpty ?? false)
            e['artist_name'] as String,
      };
      filteredFeed = feed
          .where((item) => currentFollows.contains(item.artist))
          .toList();
    } catch (_) {
      // 팔로우 목록 조회에 실패하면 필터링 없이 원본 그대로 보여줍니다.
      filteredFeed = feed;
    }

    // 찜한 공연은 아티스트 매칭을 거치지 않고 그대로 카드로 보여줍니다.
    final favoritedConcertCards = FavoritesStore.instance.favoriteConcerts
        .map(NewsModel.fromFavoritedConcert)
        .toList();

    final combined = [...favoritedConcertCards, ...filteredFeed];
    // 공연이 가까운 순(D-day 오름차순)으로 정렬합니다 — 그리드는 왼쪽
    // 위부터 오른쪽 아래로 채워지므로, 리스트 순서가 곧 화면 배치 순서가
    // 됩니다. 날짜 정보가 없는 카드는 맨 뒤로 밀립니다.
    combined.sort((a, b) {
      final da = a.concertDate;
      final db = b.concertDate;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    });
    return combined;
  }

  GlobalKey _cardKeyFor(int index) {
    while (_cardKeys.length <= index) {
      _cardKeys.add(GlobalKey());
    }
    return _cardKeys[index];
  }

  void _openNewsDetail(NewsModel item, GlobalKey cardKey, double angle) {
    final ctx = cardKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final startRect = topLeft & box.size;

    // 안 읽은 소식이면: 화면에서 먼저 읽음으로 바꾸고(NEW 배지 제거),
    // 서버에도 읽음 처리를 보냅니다(실패해도 다음 조회에서 다시 미읽음으로 올 뿐).
    final feedId = item.id;
    if (feedId != null && !item.isRead) {
      setState(() => item.isRead = true);
      unawaited(_socialService.markFeedRead(feedId).catchError((_) {}));
    }

    NewsDetailOverlay.show(
      context,
      startRect: startRect,
      collapsedCard: _PolaroidCard(data: item, angle: angle),
      news: item,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      isTabRoot: true,
      pageTop: _pageTop,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.news),
      // 페이지 상단 경계에 "페이지 뒤에서" 끼워 올린 풀탭 손잡이(빨간 하트 +
      // 방향 화살표). 우측 인덱스 탭과 같은 원리로, 경계선 위로 삐져나온
      // 부분만 보입니다.
      frameBehindPage: NewsPullTabOverlay(
        slide: _slide,
        onTap: _onPullTab,
        pageTop: _pageTop,
        heartWipe: _heartWipe,
      ),
      child: Container(color: _paperColor, child: _buildFlipBody()),
    );
  }

  /// 페이지 여백을 고정된 "액자 테두리"로 남기고, 그 안쪽 창에서만 내용이
  /// 캐러셀로 슬라이드하도록 감쌉니다.
  Widget _buildFlipBody() {
    return _NewsFrame(child: _buildWindowContent());
  }

  /// 액자 창 안에 들어갈, 현재 전환 단계별 내용.
  Widget _buildWindowContent() {
    switch (_phase) {
      case _FlipPhase.news:
        return _buildNewsBody();
      case _FlipPhase.fav:
      case _FlipPhase.loading:
        // 찜 패널을 그대로 두고, 로딩 표시는 풀탭 하트의 쐐기 회전
        // 애니메이션([_heartWipe])이 대신합니다.
        return _buildFavPanel();
      case _FlipPhase.toFav:
        // 소식 카드 페이지가 오른쪽으로 밀려나가고, 왼쪽부터 찜/아티스트
        // 검색이 들어옵니다.
        return AnimatedBuilder(
          animation: _slide,
          builder: (context, _) => CarouselSlideTransition(
            from: _buildNewsBody(),
            to: _buildFavPanel(),
            progress: _slide.value,
          ),
        );
      case _FlipPhase.toNews:
        // 반대로 찜 패널이 왼쪽으로 나가고, 오른쪽에서 소식 페이지가
        // 들어옵니다(풀탭이 1→0으로 돌아오는 동안 진행도는 0→1).
        return AnimatedBuilder(
          animation: _slide,
          builder: (context, _) => CarouselSlideTransition(
            from: _buildFavPanel(),
            to: _buildNewsBody(),
            progress: 1 - _slide.value,
            reverse: true,
          ),
        );
    }
  }

  /// 찜/아티스트 패널(같은 GlobalKey로 State 유지). 액자 창 안에 들어가므로
  /// 자체 박스 없이 창에 꽉 차는 모드로 그립니다.
  Widget _buildFavPanel() {
    return FavoritePinnedPanel(key: _favPanelKey, windowMode: true);
  }

  /// 소식 그리드 본문(로딩/에러/빈 상태 포함). GlobalKey 이유는
  /// [_newsBodyKey] 참고.
  Widget _buildNewsBody() {
    return KeyedSubtree(
      key: _newsBodyKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              return FutureBuilder<List<NewsModel>>(
                future: _newsFuture,
                builder: (context, snapshot) {
                  // [상태 1] 로딩 중: 내용은 비워 두고(빈 화면), 위에 덮인
                  // 백색 유리 글레어가 "빛 반사로 안 보이는" 상태를 대신
                  // 보여줍니다(스피너 없음).
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const SizedBox.expand();
                  }

                  // [상태 2] 에러 발생: 실패 원인(오류 코드)과 재시도 버튼.
                  if (snapshot.hasError) {
                    return _buildErrorView(snapshot.error);
                  }

                  // [상태 3] 데이터 없음
                  if (!snapshot.hasData || snapshot.data!.isEmpty) {
                    return const Center(child: Text('새로운 소식이 없습니다.'));
                  }

                  // [상태 4] 성공: 리스트 렌더링. 바깥 여백은 이제 액자
                  // 테두리([_NewsFrame])가 담당하므로, 창 안쪽에서는 카드가
                  // 테두리에 딱 붙지 않을 정도의 작은 여백만 둡니다.
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: _buildNewsGrid(constraints, snapshot.data!),
                  );
                },
              );
            },
          ),
          // 로딩 중 백색 유리 글레어(내용 위). 로딩이 끝나면 0→1로 걷혀
          // 내용이 자연스럽게 뿌옇게 → 선명하게 드러납니다.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _glassReveal,
                builder: (context, _) {
                  final revealed = Curves.easeOutCubic.transform(
                    _glassReveal.value,
                  );
                  final glare = 1.0 - revealed; // 1=완전 백색, 0=완전 투명
                  if (glare <= 0.001) return const SizedBox.shrink();
                  return Opacity(opacity: glare, child: const _GlassGlaze());
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 피드 조회 실패 화면. HTTP 오류면 상태 코드를, 그 외(네트워크 순단 등)는
  /// "연결 실패"를 보여주고 재시도 버튼을 제공합니다.
  Widget _buildErrorView(Object? error) {
    // 네트워크 단절 등 HTTP 응답 자체가 없으면 ApiClient가 statusCode -1로
    // 던지므로, 양수 코드일 때만 코드를 그대로 보여줍니다.
    final reason = error is ApiException && error.statusCode > 0
        ? '오류 (${error.statusCode})'
        : '오류 (연결 실패)';

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 48,
            color: Colors.black.withValues(alpha: 0.25),
          ),
          const SizedBox(height: 12),
          Text(
            '소식을 불러오지 못했어요.\n$reason',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(13),
              fontWeight: FontWeight.w700,
              color: Colors.black.withValues(alpha: 0.45),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: () {
              setState(() => _newsFuture = _fetchAndCacheNews());
              _armGlassReveal(_newsFuture);
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.brown,
              side: const BorderSide(color: Colors.brown),
            ),
            child: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }

  Widget _buildNewsGrid(BoxConstraints constraints, List<NewsModel> items) {
    const crossAxisCount = 2;
    const spacing = 18.0;

    // 한 행의 높이는 기존과 동일하게 "2행이 화면에 꽉 차는" 기준으로 고정합니다
    // (4개 이하일 때의 모양은 그대로 유지). 5개 이상 등록되면 physics가
    // 스크롤 가능해서 아래로 스크롤해 나머지 행을 볼 수 있습니다 — 기존에는
    // NeverScrollableScrollPhysics라 4개를 넘는 카드는 그냥 화면 밖으로
    // 잘려 안 보였습니다.
    final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: crossAxisCount,
      crossAxisSpacing: spacing,
      mainAxisSpacing: spacing,
      mainAxisExtent: (constraints.maxHeight - 60) / 2,
    );

    return GridView.builder(
      padding: EdgeInsets.zero,
      physics: const BouncingScrollPhysics(),
      gridDelegate: gridDelegate,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final angle = switch (index % 4) {
          0 => -0.02,
          1 => 0.015,
          2 => 0.012,
          _ => -0.015,
        };
        final cardKey = _cardKeyFor(index);

        return PressableScale(
          onTap: () => _openNewsDetail(item, cardKey, angle),
          pressScale: 0.97,
          tapScale: 1.02,
          child: KeyedSubtree(
            key: cardKey,
            child: _PolaroidCard(data: item, angle: angle),
          ),
        );
      },
    );
  }
}

/// 소식 페이지의 "액자" 프레임. 페이지의 크림 여백을 두껍게 남겨 고정된
/// 테두리로 삼고, 그 안쪽 창([child])에서만 내용이 캐러셀로 슬라이드합니다.
/// 창 가장자리에 진한 안쪽 그림자 + 얇은 테두리선을 얹어, 마치 액자 창
/// 아래로 페이지가 끼워져 있는 듯한 깊이감을 줍니다.
class _NewsFrame extends StatelessWidget {
  final Widget child;

  const _NewsFrame({required this.child});

  /// 액자 테두리(여백). 왼쪽은 바인더 링을 피하려 조금 더 둡니다. 위·아래는
  /// 기본(22)보다 50% 키워(33) "뚫려 보이는" 창을 세로로 더 작게 만듭니다 —
  /// 창 높이가 줄면 아래 소식 카드 그리드도 그만큼 자동으로 작아집니다
  /// ([_buildNewsGrid]가 창 높이에 맞춰 카드 크기를 계산).
  static const EdgeInsets _insets = EdgeInsets.fromLTRB(30, 33, 22, 33);
  static const double _windowRadius = 6;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: _insets,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 창: 슬라이드되는 내용(창 밖으로 넘친 부분은 잘라냄).
          ClipRRect(
            borderRadius: BorderRadius.circular(_windowRadius),
            child: child,
          ),
          // 유리 광택(내용 위, 프레임의 일부라 슬라이드해도 고정). 그 아래로
          // 내용이 지나가서 "유리 낀 액자"처럼 보입니다.
          const Positioned.fill(
            child: IgnorePointer(
              child: _GlassGloss(radius: _windowRadius),
            ),
          ),
          // 액자 안쪽 그림자 + 얇은 테두리(가장 위, 터치는 통과).
          const Positioned.fill(
            child: IgnorePointer(
              child: _InnerShadowFrame(radius: _windowRadius),
            ),
          ),
        ],
      ),
    );
  }
}

/// 로딩 중 창 전체를 덮는 "강한 백색 유리 글레어". 빛 반사가 너무 커서
/// 유리 너머 내용이 안 보이는 상태를 표현합니다 — 거의 불투명한 백색 위에
/// 더 밝은 대각선 반사 띠와 살짝의 하늘색 유리 기운을 얹습니다. 로딩이
/// 끝나면 이 위젯을 감싼 [Opacity]가 1→0으로 걷혀 내용이 드러납니다.
class _GlassGlaze extends StatelessWidget {
  const _GlassGlaze();

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [
        // 1) 거의 불투명한 백색 반사(내용이 비치지 않을 정도).
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFFFFFFF),
                Color(0xFAFFFFFF),
                Color(0xF5FFFFFF),
              ],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
        ),
        // 2) 더 밝은(순백) 대각선 반사 띠.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [
                Color(0x00FFFFFF),
                Color(0x00FFFFFF),
                Color(0xFFFFFFFF),
                Color(0xFFFFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: [0.0, 0.32, 0.42, 0.52, 0.86],
            ),
          ),
        ),
        // 3) 가장자리에 살짝 도는 하늘색 유리 기운.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-0.5, -0.6),
              radius: 1.3,
              colors: [Color(0x33BFE1FF), Color(0x00BFE1FF)],
              stops: [0.0, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

/// 창 위에 얹는 유리 광택 오버레이. 왼쪽 위에서 은은하게 번지는 반사광 +
/// 대각선으로 지나가는 얇은 광택 줄을 겹쳐, 액자에 유리가 끼워진 느낌을
/// 냅니다. 순수 장식이라 터치는 통과합니다.
class _GlassGloss extends StatelessWidget {
  final double radius;

  const _GlassGloss({required this.radius});

  /// 유리 광택의 색조 — 순수 흰색 대신 살짝 하늘색을 섞어 유리처럼 보이게.
  static const Color _tint = Color(0xFFBFE1FF);

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1) 왼쪽 위 코너에서 부드럽게 번지는 반사광.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _tint.withValues(alpha: 0.3),
                  _tint.withValues(alpha: 0.12),
                  _tint.withValues(alpha: 0.02),
                  _tint.withValues(alpha: 0.0),
                  _tint.withValues(alpha: 0.08),
                ],
                stops: const [0.0, 0.24, 0.52, 0.8, 1.0],
              ),
            ),
          ),
          // 2) 오른쪽 위 → 왼쪽 아래로 지나가는, 경계가 또렷한 대각선 광택 띠.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  _tint.withValues(alpha: 0.0),
                  _tint.withValues(alpha: 0.0),
                  _tint.withValues(alpha: 0.6),
                  _tint.withValues(alpha: 0.6),
                  _tint.withValues(alpha: 0.0),
                  _tint.withValues(alpha: 0.0),
                ],
                // 램프 구간(0.35↔0.37, 0.44↔0.46)을 좁혀 띠 양 끝이 선명하게.
                stops: const [0.0, 0.35, 0.37, 0.44, 0.46, 1.0],
              ),
            ),
          ),
          // 3) 그 옆에 나란히 지나가는 두 번째(더 얇은) 광택 띠.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  _tint.withValues(alpha: 0.0),
                  _tint.withValues(alpha: 0.0),
                  _tint.withValues(alpha: 0.4),
                  _tint.withValues(alpha: 0.4),
                  _tint.withValues(alpha: 0.0),
                  _tint.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 0.57, 0.585, 0.62, 0.635, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 창 안쪽 네 변에 그림자를 드리워(안쪽으로 파인) 액자 느낌을 내는 오버레이.
/// Flutter에 내장된 inset 그림자가 없어, 각 변에 검정→투명 그라데이션 띠를
/// 얹어 흉내 냅니다.
class _InnerShadowFrame extends StatelessWidget {
  final double radius;

  const _InnerShadowFrame({required this.radius});

  /// 그림자가 안쪽으로 번지는 두께(px)와 진하기(alpha). "두껍고 뚜렷하게"에
  /// 맞춰 넉넉히 잡았습니다.
  static const double _reach = 14;
  static const double _alpha = 0.34;

  @override
  Widget build(BuildContext context) {
    Widget edge({
      double? left,
      double? top,
      double? right,
      double? bottom,
      double? width,
      double? height,
      required Alignment begin,
      required Alignment end,
    }) {
      return Positioned(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: begin,
              end: end,
              colors: [
                Colors.black.withValues(alpha: _alpha),
                Colors.black.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        // 그라데이션 띠는 창 모서리 둥근 부분 밖으로 삐져나오지 않게 클립합니다.
        ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            children: [
              edge(
                left: 0,
                top: 0,
                right: 0,
                height: _reach,
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              edge(
                left: 0,
                bottom: 0,
                right: 0,
                height: _reach,
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
              ),
              edge(
                left: 0,
                top: 0,
                bottom: 0,
                width: _reach,
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              edge(
                right: 0,
                top: 0,
                bottom: 0,
                width: _reach,
                begin: Alignment.centerRight,
                end: Alignment.centerLeft,
              ),
            ],
          ),
        ),
        // 창 경계를 또렷하게 하는 얇은 테두리선.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: Colors.black.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PolaroidCard extends StatelessWidget {
  final NewsModel data;
  final double angle;

  const _PolaroidCard({required this.data, required this.angle});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(4),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 10,
              offset: const Offset(4, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      // 찜한 공연 카드는 좌상단에 아티스트 이름 대신 공연
                      // D-day를 보여줍니다(며칠 남았는지 한눈에 보이도록).
                      data.isFavoritedConcert
                          ? data.concertDDayLabel
                          : data.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.sp(11),
                        fontWeight: FontWeight.bold,
                        color: Colors.black.withValues(alpha: 0.4),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  // 아직 안 읽은 소식 표시(상세를 열면 사라짐)
                  if (!data.isRead)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE0455E),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'NEW',
                        style: TextStyle(
                          fontSize: context.sp(8),
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  // 포스터가 없거나 로드에 실패하면 그라데이션 플레이스홀더로
                  // 폴백합니다(깨진 이미지 아이콘 대신).
                  child: SizedBox.expand(
                    child: PosterBackground(imageUrl: data.imageUrl),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                data.concert,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.sp(13),
                  fontWeight: FontWeight.w900,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                data.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.sp(11),
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade600,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
