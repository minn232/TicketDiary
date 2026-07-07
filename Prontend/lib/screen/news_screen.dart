import 'package:flutter/material.dart';
import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/services/favorites_store.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';
import 'package:ticketdiary/widgets/pressable_scale.dart';

import 'news_detail_overlay.dart';

// =============================================================================
// [소식 탭 로드맵] 추후 아래 3가지 소스에서 가져온 소식을 함께 보여줄 예정입니다.
// 1. 설정(인덱스) 탭에서 "찜"한 아티스트의 새 공연 소식
// 2. 설정(인덱스) 탭에서 "찜"한 공연의 소식
// 3. 추천 공연 소식
// 지금은 세 종류를 구분하지 않고 NewsApiService가 하나의 통합 목록만 반환한다고
// 가정해 두었습니다. 실제 연동 시 백엔드가 이 3가지를 합쳐서 내려줄지, 종류별로
// 나눠서 내려줄지에 따라 NewsApiService/NewsModel과 화면 구성(탭·섹션 분리 등)을
// 조정하면 됩니다.
// =============================================================================

/// [준비 2] API 서비스 레이어
/// 실제 서버 연동 시 http/dio 패키지를 사용하여 여기를 채우면 됩니다.
class NewsApiService {
  /// [favoriteArtistNames]/[favoriteConcertNames]는 설정 > 선호 아티스트 / 찜 공연
  /// 화면([FavoritesStore])에서 가져온 찜 목록입니다. 백엔드 연동 시 이 목록을
  /// 쿼리 파라미터 등으로 실어 보내, 찜한 아티스트/공연에 대한 소식만 받아오면 됩니다.
  static Future<List<NewsModel>> fetchNewsItems({
    required List<String> favoriteArtistNames,
    required List<String> favoriteConcertNames,
  }) async {
    // TODO: 백엔드 연동 시 이 부분을 실제 HTTP 호출로 교체하세요.
    // 지금은 오류 발생 시 대체 화면(_fallbackNewsItems)이 잘 보이는지
    // 확인할 수 있도록 일부러 예외를 던지는 상태로 두었습니다.
    await Future.delayed(const Duration(milliseconds: 300));
    throw Exception('소식 데이터를 불러오지 못했습니다.');
  }
}

/// [준비 3] 소식을 불러오다 오류가 발생했을 때 대신 보여줄 더미 데이터.
/// 실제 서버 연동 후에도 응답 파싱 실패 등 예외 상황에서 화면이 완전히 비지
/// 않도록, 최소 한 장의 예시 카드를 보여주는 용도로 사용합니다.
final List<NewsModel> _fallbackNewsItems = [
  NewsModel(
    artist: '알 수 없는 아티스트',
    concert: '알 수 없는 공연',
    imageUrl: '',
    description: '소식을 불러오지 못했습니다.',
    content: '소식 내용을 불러오지 못했습니다. 잠시 후 다시 시도해주세요.',
    // 백엔드 연동 전이라 일부러 빈 URL을 둬서, 상세 화면에서 깨진 이미지로 보이도록 합니다.
    articleImageUrl: '',
  ),
];

class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key});

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  static const Color _paperColor = Color(0xFFF4F1E1);
  late Future<List<NewsModel>> _newsFuture;

  /// 카드 확장 애니메이션의 시작 Rect를 구하기 위한, 카드 인덱스별 key.
  final List<GlobalKey> _cardKeys = [];

  @override
  void initState() {
    super.initState();
    // 화면 초기화 시 데이터 호출 시작
    _newsFuture = _loadNews();
  }

  Future<List<NewsModel>> _loadNews() async {
    // 찜 목록을 먼저 불러온 뒤, 그 목록을 기준으로 소식을 요청합니다.
    await FavoritesStore.instance.load();
    return NewsApiService.fetchNewsItems(
      favoriteArtistNames: FavoritesStore.instance.favoriteArtists
          .map((a) => a.name)
          .toList(),
      favoriteConcertNames: FavoritesStore.instance.favoriteConcerts
          .map((c) => c.name)
          .toList(),
    );
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

                // [상태 2] 에러 발생: 더미 데이터로 대체해서 보여줍니다.
                if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(32, 20, 20, 20),
                    child: _buildNewsGrid(constraints, _fallbackNewsItems),
                  );
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
              Text(
                data.artist,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.black.withValues(alpha: 0.4),
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Image.network(
                    data.imageUrl,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: double.infinity,
                      height: double.infinity,
                      color: Colors.grey.shade200,
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                data.concert,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
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
                  fontSize: 11,
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
