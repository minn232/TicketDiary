import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/services/api_client.dart';
import 'package:ticketdiary/services/favorites_store.dart';
import 'package:ticketdiary/services/news_cache_store.dart';
import 'package:ticketdiary/services/news_loading_signal.dart';
import 'package:ticketdiary/services/social_service.dart';
import 'package:ticketdiary/widgets/checkerboard_reveal_transition.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/magic_loading_overlay.dart';
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
///
/// - [news]: 소식 그리드만 보임(풀탭은 왼쪽 끝).
/// - [toFav]: 풀탭이 오른쪽으로 이동하며 체커보드로 찜 패널이 왼쪽부터 드러남.
/// - [fav]: 찜/아티스트 패널만 보임(풀탭은 오른쪽 끝).
/// - [loading]: 풀탭을 다시 눌러 최신 소식을 준비하는 동안. 전환은 멈추고
///   마법 로딩 오버레이(안개+반짝이)를 찜 패널 위에 겹쳐 보여줍니다.
/// - [toNews]: 최신 소식이 준비되면 풀탭이 왼쪽으로 돌아오며 역체커보드로
///   최신 소식이 드러남.
enum _FlipPhase { news, toFav, fav, loading, toNews }

class _NewsScreenState extends State<NewsScreen>
    with SingleTickerProviderStateMixin {
  static const Color _paperColor = Color(0xFFF4F1E1);

  /// 소식 페이지 상단 여백을 기본(10)보다 늘려, 페이지 뒤에서 끼워 올린
  /// 풀탭 손잡이가 상단 경계선 위로 삐져나올 공간을 만듭니다.
  static const double _pageTop = 40;

  late Future<List<NewsModel>> _newsFuture;

  final SocialService _socialService = SocialService();

  /// 카드 확장 애니메이션의 시작 Rect를 구하기 위한, 카드 인덱스별 key.
  final List<GlobalKey> _cardKeys = [];

  /// 로딩이 10초를 넘으면(혹시 모를 무한 로딩 오류 대비) 인덱스 탭 전환
  /// 애니메이션의 대기를 강제로 풀어, 화면 자체의 로딩 스피너로 넘어가게
  /// 합니다.
  Timer? _loadingHoldTimeout;

  // ─── 풀탭 전환 상태 ───────────────────────────────────────────────
  /// 풀탭 위치이자 체커보드 진행도의 원천. 0.0=소식/왼쪽, 1.0=찜/오른쪽.
  late final AnimationController _slide;

  _FlipPhase _phase = _FlipPhase.news;

  /// 찜 패널은 전환/로딩 여러 단계에 걸쳐 살아 있어야(검색어·찜 토글 유지)
  /// 하므로, 같은 GlobalKey로 만들어 트리 위치가 바뀌어도 State가 유지되게
  /// 합니다.
  final GlobalKey _favPanelKey = GlobalKey();

  /// 복귀 시 최신 소식 로딩이 너무 오래 걸리면(백엔드 오류 등) 기존
  /// 데이터로라도 소식으로 되돌아오게 하는 안전 타임아웃.
  Timer? _returnTimeout;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    )..addStatusListener(_onSlideStatus);

    NewsLoadingSignal.isLoading.value = true;
    _loadingHoldTimeout = Timer(const Duration(seconds: 10), () {
      NewsLoadingSignal.isLoading.value = false;
    });
    // 화면 초기화 시 데이터 호출 시작
    _newsFuture = _loadNewsWithCache();
    unawaited(
      _newsFuture.whenComplete(() {
        _loadingHoldTimeout?.cancel();
        NewsLoadingSignal.isLoading.value = false;
      }),
    );
  }

  @override
  void dispose() {
    _loadingHoldTimeout?.cancel();
    _returnTimeout?.cancel();
    _slide.dispose();
    super.dispose();
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
  /// 전환을 멈추고 마법 오버레이만 보여주다가, 준비되면 역체커보드로
  /// 최신 소식을 드러냅니다.
  void _startReturnToNews() {
    setState(() => _phase = _FlipPhase.loading);

    var settled = false;
    void finish(Future<List<NewsModel>> future) {
      if (!mounted || settled) return;
      settled = true;
      _returnTimeout?.cancel();
      _revealFreshNews(future);
    }

    _returnTimeout?.cancel();
    _returnTimeout = Timer(const Duration(seconds: 10), () {
      // 타임아웃: 기존 데이터로라도 소식으로 복귀합니다.
      finish(_newsFuture);
    });

    _fetchAndCacheNews()
        .then((items) => finish(Future.value(items)))
        .catchError((Object e) => finish(Future.error(e)));
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
    // FavoritesStore.load()는 이미 로드됐으면 곧장 반환하므로(멱등),
    // 여기서 먼저 호출해도 안전합니다 — 캐시가 "지금" 찜 목록 기준으로
    // 여전히 유효한지 판단하려면 revision이 최신 상태여야 합니다.
    await FavoritesStore.instance.load();
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
    await FavoritesStore.instance.load();
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

    return [...favoritedConcertCards, ...filteredFeed];
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
      unawaited(
        _socialService.markFeedRead(feedId).catchError((_) {}),
      );
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
      ),
      child: Container(
        color: _paperColor,
        child: _buildFlipBody(),
      ),
    );
  }

  /// 현재 전환 단계에 맞는 페이지 본문을 만듭니다.
  Widget _buildFlipBody() {
    switch (_phase) {
      case _FlipPhase.news:
        return _buildNewsBody();
      case _FlipPhase.fav:
        return _buildFavPanel();
      case _FlipPhase.loading:
        // 찜 패널을 그대로 두고 그 위에 마법 로딩 오버레이(안개+반짝이).
        return Stack(
          fit: StackFit.expand,
          children: [
            _buildFavPanel(),
            const MagicLoadingOverlay(),
          ],
        );
      case _FlipPhase.toFav:
        return AnimatedBuilder(
          animation: _slide,
          builder: (context, _) => CheckerboardRevealTransition(
            from: _buildNewsBody(),
            to: _buildFavPanel(),
            progress: _slide.value,
          ),
        );
      case _FlipPhase.toNews:
        return AnimatedBuilder(
          animation: _slide,
          builder: (context, _) => CheckerboardRevealTransition(
            from: _buildFavPanel(),
            to: _buildNewsBody(),
            // 풀탭이 오른쪽(1)→왼쪽(0)으로 돌아오는 동안 최신 소식이 오른쪽
            // 부터 드러나도록, 진행도를 뒤집고 방향도 반대로 합니다.
            progress: 1 - _slide.value,
            reverse: true,
          ),
        );
    }
  }

  /// 찜/아티스트 패널(같은 GlobalKey로 State 유지).
  Widget _buildFavPanel() {
    return FavoritePinnedPanel(key: _favPanelKey);
  }

  /// 소식 그리드 본문(로딩/에러/빈 상태 포함).
  Widget _buildNewsBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return FutureBuilder<List<NewsModel>>(
          future: _newsFuture,
          builder: (context, snapshot) {
            // [상태 1] 로딩 중
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.brown),
              );
            }

            // [상태 2] 에러 발생: 실패 원인(오류 코드)과 재시도 버튼.
            if (snapshot.hasError) {
              return _buildErrorView(snapshot.error);
            }

            // [상태 3] 데이터 없음
            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return const Center(child: Text('새로운 소식이 없습니다.'));
            }

            // [상태 4] 성공: 리스트 렌더링. 손잡이는 페이지 뒤에 있어 본문을
            // 가리지 않으므로 상단 패딩은 기본값만 둡니다.
            return Padding(
              padding: const EdgeInsets.fromLTRB(32, 14, 20, 20),
              child: _buildNewsGrid(constraints, snapshot.data!),
            );
          },
        );
      },
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
            onPressed: () => setState(() => _newsFuture = _fetchAndCacheNews()),
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
                      data.artist,
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
