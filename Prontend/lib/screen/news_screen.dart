import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/services/api_client.dart';
import 'package:ticketdiary/services/favorites_store.dart';
import 'package:ticketdiary/services/social_service.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/poster_background.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';
import 'package:ticketdiary/widgets/pressable_scale.dart';
import 'package:ticketdiary/widgets/responsive_text.dart';

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

class _NewsScreenState extends State<NewsScreen> {
  static const Color _paperColor = Color(0xFFF4F1E1);
  late Future<List<NewsModel>> _newsFuture;

  final SocialService _socialService = SocialService();

  /// 카드 확장 애니메이션의 시작 Rect를 구하기 위한, 카드 인덱스별 key.
  final List<GlobalKey> _cardKeys = [];

  @override
  void initState() {
    super.initState();
    // 화면 초기화 시 데이터 호출 시작
    _newsFuture = _loadNews();
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
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.news),
      child: Container(
        color: _paperColor,
        child: LayoutBuilder(
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

                // [상태 2] 에러 발생: 실패 원인(오류 코드)과 재시도 버튼을
                // 보여줍니다.
                if (snapshot.hasError) {
                  return _buildErrorView(snapshot.error);
                }

                // [상태 3] 데이터 없음
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return const Center(child: Text('새로운 소식이 없습니다.'));
                }

                // [상태 4] 성공: 리스트 렌더링
                return Padding(
                  padding: const EdgeInsets.fromLTRB(32, 20, 20, 20),
                  child: _buildNewsGrid(constraints, snapshot.data!),
                );
              },
            );
          },
        ),
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
            onPressed: () => setState(() => _newsFuture = _loadNews()),
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

    final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: crossAxisCount,
      crossAxisSpacing: spacing,
      mainAxisSpacing: spacing,
      mainAxisExtent: (constraints.maxHeight - 60) / 2,
    );

    return GridView.builder(
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
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
