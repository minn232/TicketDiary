import 'dart:async';

import 'package:flutter/material.dart';

import 'package:ticketdiary/models/artist_model.dart';
import 'package:ticketdiary/models/concert_model.dart';
import 'package:ticketdiary/services/artist_search_service.dart';
import 'package:ticketdiary/services/concert_search_service.dart';
import 'package:ticketdiary/services/favorites_store.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';
import 'package:ticketdiary/widgets/responsive_text.dart';

/// 선호 아티스트 / 찜 공연 검색 화면을 [DiaryPageFrame]으로 감싼 독립
/// 화면(라우트로 진입할 때 사용). 실제 내용은 [FavoritePinnedPanel]이며,
/// 소식 탭에서는 프레임 없이 이 패널만 페이지 안에 끼워 씁니다.
class FavoritePinnedSettingsScreen extends StatelessWidget {
  const FavoritePinnedSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.settings),
      child: FavoritePinnedPanel(onBack: () => Navigator.pop(context)),
    );
  }
}

/// 선호 아티스트 / 찜 공연 검색 패널(프레임 없음).
///
/// - 검색창에 타이핑하면(별도 검색 버튼 없이) 잠깐 멈출 때마다 자동으로
///   백엔드(KOPIS 실시간 검색)에서 아티스트/공연을 찾아 아래에 보여줍니다.
/// - 결과 카드를 누르면 찜 토글되며, 이 찜 목록은 [FavoritesStore]를 통해
///   기기 로컬과 서버(`/social/artists`, `/social/concerts`) 양쪽에 저장되어
///   소식 탭 피드 생성에 사용됩니다.
/// - 상단 "관리" 버튼으로 현재 찜한 아티스트/공연을 한눈에 보고 해제할 수 있습니다.
/// - [onBack]이 null이면 상단 뒤로가기 버튼을 숨깁니다(소식 탭에 끼워 쓸
///   때처럼 풀탭 조각이 복귀를 담당하는 경우).
class FavoritePinnedPanel extends StatefulWidget {
  final VoidCallback? onBack;

  const FavoritePinnedPanel({super.key, this.onBack});

  @override
  State<FavoritePinnedPanel> createState() => _FavoritePinnedPanelState();
}

class _FavoritePinnedPanelState extends State<FavoritePinnedPanel> {
  final ArtistSearchService _artistSearchService = BackendArtistSearchService();
  final ConcertSearchService _concertSearchService =
      BackendConcertSearchService();
  final FavoritesStore _favorites = FavoritesStore.instance;

  final TextEditingController _artistQueryController = TextEditingController();
  final TextEditingController _concertQueryController = TextEditingController();

  /// 선호 아티스트/찜 공연 검색을 좌우 스와이프로 넘나드는 페이지 컨트롤러.
  final PageController _categoryPageController = PageController();
  _FavCategory _currentCategory = _FavCategory.artist;

  void _onCategoryPageChanged(int index) {
    setState(() => _currentCategory = _FavCategory.values[index]);
  }

  void _goToCategory(_FavCategory category) {
    _categoryPageController.animateToPage(
      category.index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  /// 매 키 입력마다 KOPIS 실시간 검색을 부르지 않도록, 타이핑이 잠깐
  /// 멈춘 뒤에 검색을 실행합니다.
  static const _debounce = Duration(milliseconds: 450);
  Timer? _artistDebounce;
  Timer? _concertDebounce;

  List<ArtistModel> _artistResults = const [];
  List<ConcertModel> _concertResults = const [];
  bool _artistSearching = false;
  bool _concertSearching = false;
  bool _artistSearchFailed = false;
  bool _concertSearchFailed = false;

  @override
  void initState() {
    super.initState();
    _favorites.load();
    // 다른 기기/이전 세션에서 서버에 저장해둔 찜도 불러와 합칩니다.
    unawaited(_favorites.syncFromServer());
    _favorites.addListener(_onFavoritesChanged);
    _artistQueryController.addListener(_onArtistQueryChanged);
    _concertQueryController.addListener(_onConcertQueryChanged);
  }

  @override
  void dispose() {
    _artistDebounce?.cancel();
    _concertDebounce?.cancel();
    _favorites.removeListener(_onFavoritesChanged);
    _artistQueryController.dispose();
    _concertQueryController.dispose();
    _categoryPageController.dispose();
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onArtistQueryChanged() {
    _artistDebounce?.cancel();
    final query = _artistQueryController.text;
    if (query.trim().isEmpty) {
      setState(() {
        _artistResults = const [];
        _artistSearching = false;
        _artistSearchFailed = false;
      });
      return;
    }
    setState(() => _artistSearching = true);
    _artistDebounce = Timer(_debounce, () => _runArtistSearch(query));
  }

  Future<void> _runArtistSearch(String query) async {
    try {
      final results = await _artistSearchService.search(query);
      if (!mounted || _artistQueryController.text != query) return;
      setState(() {
        _artistResults = results;
        _artistSearching = false;
        _artistSearchFailed = false;
      });
    } catch (_) {
      if (!mounted || _artistQueryController.text != query) return;
      setState(() {
        _artistResults = const [];
        _artistSearching = false;
        _artistSearchFailed = true;
      });
    }
  }

  void _onConcertQueryChanged() {
    _concertDebounce?.cancel();
    final query = _concertQueryController.text;
    if (query.trim().isEmpty) {
      setState(() {
        _concertResults = const [];
        _concertSearching = false;
        _concertSearchFailed = false;
      });
      return;
    }
    setState(() => _concertSearching = true);
    _concertDebounce = Timer(_debounce, () => _runConcertSearch(query));
  }

  Future<void> _runConcertSearch(String query) async {
    try {
      final results = await _concertSearchService.search(query);
      if (!mounted || _concertQueryController.text != query) return;
      setState(() {
        _concertResults = results;
        _concertSearching = false;
        _concertSearchFailed = false;
      });
    } catch (_) {
      if (!mounted || _concertQueryController.text != query) return;
      setState(() {
        _concertResults = const [];
        _concertSearching = false;
        _concertSearchFailed = true;
      });
    }
  }

  /// 결과가 비어 있을 때 결과 영역에 보여줄 안내 문구.
  String get _artistStatusText {
    if (_artistSearchFailed) return '검색에 실패했어요. 잠시 후 다시 시도해주세요.';
    if (_artistQueryController.text.trim().isEmpty) return '검색어를 입력해보세요.';
    return '검색 결과가 없습니다.';
  }

  String get _concertStatusText {
    if (_concertSearchFailed) return '검색에 실패했어요. 잠시 후 다시 시도해주세요.';
    if (_concertQueryController.text.trim().isEmpty) return '검색어를 입력해보세요.';
    return '검색 결과가 없습니다.';
  }

  // [백엔드 수정]
  // 이미 티켓 등록된 공연이면 서버가 찜을 거부하므로 안내 문구를 띄움
  Future<void> _onConcertTap(ConcertModel c) async {
    final rejected = await _favorites.toggleConcert(c);
    if (!mounted || !rejected) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('이미 티켓으로 등록된 공연입니다')));
  }

  void _openManageSheet() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '찜 관리 닫기',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Stack(
          children: [
            // 패널 바깥(빈 공간)을 누르면 뒤로가기
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: MediaQuery.of(context).size.width * 0.5,
                height: MediaQuery.of(context).size.height * 0.5,
                // 패널 내부 탭이 바깥 탭으로 오인되어 닫히지 않도록 흡수
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: _ManageFavoritesSheet(favorites: _favorites),
                ),
              ),
            ),
          ],
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 18, 18, 18),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Colors.black.withValues(alpha: 0.12),
            width: 1.2,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Column(
            children: [
              _TopBar(
                title: '아티스트 / 찜 공연',
                onBack: widget.onBack,
                onManage: _openManageSheet,
              ),
              const Divider(height: 1, thickness: 1),
              // 좌우 스와이프로 두 검색 페이지를 넘나든다는 걸 알기 쉽도록,
              // 탭처럼 누를 수도 있는 알약 모양 스위처 + 화살표 힌트를
              // PageView 바로 위에 고정으로 둡니다.
              _CategorySwitcher(
                current: _currentCategory,
                onSelect: _goToCategory,
              ),
              Expanded(
                child: PageView(
                  controller: _categoryPageController,
                  onPageChanged: _onCategoryPageChanged,
                  children: [
                    _CategorySearchPage<ArtistModel>(
                      controller: _artistQueryController,
                      hintText: '아티스트 이름 검색',
                      items: _artistResults,
                      searching: _artistSearching,
                      statusText: _artistStatusText,
                      nameOf: (a) => a.name,
                      imageUrlOf: (a) => a.profileImageUrl,
                      // 아티스트 프로필 사진은 백엔드에 소스가 없어
                      // 사람 아이콘 플레이스홀더를 보여줍니다.
                      placeholderIcon: Icons.person_outline,
                      isFavoritedOf: (a) =>
                          _favorites.isArtistFavorited(a.name),
                      onTap: (a) => _favorites.toggleArtist(a),
                    ),
                    _CategorySearchPage<ConcertModel>(
                      controller: _concertQueryController,
                      hintText: '공연 이름 검색',
                      items: _concertResults,
                      searching: _concertSearching,
                      statusText: _concertStatusText,
                      nameOf: (c) => c.name,
                      imageUrlOf: (c) => c.posterImageUrl,
                      isFavoritedOf: (c) =>
                          _favorites.isConcertFavorited(c.name),
                      onTap: _onConcertTap,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String title;

  /// null이면 뒤로가기 버튼을 숨깁니다(소식 탭 내장 모드처럼 풀탭 조각이
  /// 복귀를 담당하는 경우).
  final VoidCallback? onBack;
  final VoidCallback onManage;

  const _TopBar({
    required this.title,
    required this.onBack,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(onBack == null ? 18 : 10, 10, 10, 10),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.chevron_left),
              color: Colors.black.withValues(alpha: 0.75),
            ),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: context.sp(15),
                fontWeight: FontWeight.w900,
                color: Colors.black87,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onManage,
            icon: const Icon(Icons.tune, size: 16),
            label: const Text('관리'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.black.withValues(alpha: 0.65),
              textStyle: TextStyle(
                fontSize: context.sp(13),
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _FavCategory { artist, concert }

/// 선호 아티스트/찜 공연 검색 페이지 중 하나를 통째로 그립니다 — 검색창은
/// 항상 페이지 내부 상단에 고정되고, 그 아래로 결과 그리드가 스크롤됩니다.
class _CategorySearchPage<T> extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final List<T> items;
  final bool searching;
  final String statusText;
  final String Function(T) nameOf;
  final String Function(T) imageUrlOf;
  final IconData placeholderIcon;
  final bool Function(T) isFavoritedOf;
  final ValueChanged<T> onTap;

  const _CategorySearchPage({
    super.key,
    required this.controller,
    required this.hintText,
    required this.items,
    required this.searching,
    required this.statusText,
    required this.nameOf,
    required this.imageUrlOf,
    this.placeholderIcon = Icons.broken_image_outlined,
    required this.isFavoritedOf,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SearchField(controller: controller, hintText: hintText),
          const SizedBox(height: 14),
          Expanded(
            child: _SearchResultsGrid<T>(
              items: items,
              searching: searching,
              statusText: statusText,
              nameOf: nameOf,
              imageUrlOf: imageUrlOf,
              placeholderIcon: placeholderIcon,
              isFavoritedOf: isFavoritedOf,
              onTap: onTap,
            ),
          ),
        ],
      ),
    );
  }
}

/// 페이지 상단에 고정으로 두는, 두 검색 페이지 사이를 탭으로도 이동할 수
/// 있는 알약형 스위처. 좌우에 화살표를 둬서(현재 페이지 반대쪽만 진하게)
/// 좌우 스와이프로도 넘어갈 수 있다는 걸 알기 쉽게 합니다.
class _CategorySwitcher extends StatelessWidget {
  final _FavCategory current;
  final ValueChanged<_FavCategory> onSelect;

  const _CategorySwitcher({required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final canGoLeft = current == _FavCategory.concert;
    final canGoRight = current == _FavCategory.artist;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(
        children: [
          Icon(
            Icons.chevron_left,
            size: 20,
            color: Colors.black.withValues(alpha: canGoLeft ? 0.45 : 0.12),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _CategoryPill(
                    label: '선호 아티스트',
                    selected: current == _FavCategory.artist,
                    onTap: () => onSelect(_FavCategory.artist),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CategoryPill(
                    label: '찜 공연',
                    selected: current == _FavCategory.concert,
                    onTap: () => onSelect(_FavCategory.concert),
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            size: 20,
            color: Colors.black.withValues(alpha: canGoRight ? 0.45 : 0.12),
          ),
        ],
      ),
    );
  }
}

class _CategoryPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF8D6E63)
              : Colors.white.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Colors.black.withValues(alpha: selected ? 0 : 0.15),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: context.sp(13),
            fontWeight: FontWeight.w900,
            color: selected ? Colors.white : Colors.black.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}

/// 검색 버튼 없이, 입력할 때마다 바로 검색되는 것을 알려주는 검색창.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;

  const _SearchField({required this.controller, required this.hintText});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.black.withValues(alpha: 0.22),
          width: 1.3,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(
            Icons.search,
            size: 18,
            color: Colors.black.withValues(alpha: 0.35),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: hintText,
                hintStyle: TextStyle(
                  fontSize: context.sp(14),
                  fontWeight: FontWeight.w900,
                  color: Colors.black.withValues(alpha: 0.25),
                ),
              ),
              style: TextStyle(
                fontSize: context.sp(14),
                fontWeight: FontWeight.w900,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 검색 결과를 3열 그리드로 보여줍니다(세로 스크롤로 더 많은 결과를 볼 수
/// 있음, 카드 크기는 항상 동일하게 유지).
class _SearchResultsGrid<T> extends StatelessWidget {
  final List<T> items;

  /// true면 결과 대신 로딩 스피너를 보여줍니다(검색 요청 진행 중).
  final bool searching;

  /// 결과가 비어 있을 때 보여줄 안내 문구(미입력/결과 없음/검색 실패).
  final String statusText;

  final String Function(T) nameOf;
  final String Function(T) imageUrlOf;

  /// 이미지가 없거나 로드에 실패했을 때 보여줄 아이콘.
  final IconData placeholderIcon;

  final bool Function(T) isFavoritedOf;
  final ValueChanged<T> onTap;

  const _SearchResultsGrid({
    required this.items,
    required this.searching,
    required this.statusText,
    required this.nameOf,
    required this.imageUrlOf,
    this.placeholderIcon = Icons.broken_image_outlined,
    required this.isFavoritedOf,
    required this.onTap,
  });

  static const _crossAxisCount = 3;
  static const _spacing = 12.0;

  @override
  Widget build(BuildContext context) {
    if (searching) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.brown),
        ),
      );
    }

    if (items.isEmpty) {
      return Center(
        child: Text(
          statusText,
          style: TextStyle(
            fontSize: context.sp(12),
            color: Colors.black.withValues(alpha: 0.3),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth =
            (constraints.maxWidth - _spacing * (_crossAxisCount - 1)) /
            _crossAxisCount;
        final cellHeight = cardWidth + 34;

        return GridView.builder(
          padding: EdgeInsets.zero,
          physics: const BouncingScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _crossAxisCount,
            crossAxisSpacing: _spacing,
            mainAxisSpacing: _spacing,
            mainAxisExtent: cellHeight,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _ThumbCard(
              label: nameOf(item),
              imageUrl: imageUrlOf(item),
              placeholderIcon: placeholderIcon,
              favorited: isFavoritedOf(item),
              onTap: () => onTap(item),
            );
          },
        );
      },
    );
  }
}

class _ThumbCard extends StatelessWidget {
  final String label;
  final String imageUrl;
  final IconData placeholderIcon;
  final bool favorited;
  final VoidCallback onTap;

  const _ThumbCard({
    required this.label,
    required this.imageUrl,
    this.placeholderIcon = Icons.broken_image_outlined,
    required this.favorited,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: favorited
                            ? const Color(0xFFEF4444)
                            : Colors.black.withValues(alpha: 0.20),
                        width: favorited ? 2.4 : 1.2,
                      ),
                    ),
                    child: imageUrl.isEmpty
                        ? _ThumbPlaceholder(icon: placeholderIcon)
                        : Image.network(
                            imageUrl,
                            fit: BoxFit.cover,
                            // KOPIS 포스터 서버는 CORS 헤더를 주지 않아 웹에서
                            // 일반 로드가 실패합니다. 실패 시 <img> 태그로
                            // 대신 렌더링해 포스터가 보이게 합니다(웹 전용,
                            // 모바일에는 영향 없음).
                            webHtmlElementStrategy:
                                WebHtmlElementStrategy.fallback,
                            errorBuilder: (context, error, stackTrace) =>
                                _ThumbPlaceholder(icon: placeholderIcon),
                          ),
                  ),
                ),
                if (favorited)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: Color(0xFFEF4444),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.favorite,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(12),
              fontWeight: FontWeight.w900,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

/// 이미지가 없거나 로드에 실패했을 때 보여주는 placeholder.
/// 아티스트는 사람 아이콘, 공연은 깨진 이미지 아이콘을 씁니다.
class _ThumbPlaceholder extends StatelessWidget {
  final IconData icon;

  const _ThumbPlaceholder({this.icon = Icons.broken_image_outlined});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade200,
      alignment: Alignment.center,
      child: Icon(icon, size: 30, color: Colors.grey),
    );
  }
}

/// "관리" 버튼을 누르면 뜨는, 현재 찜한 아티스트/공연 목록 + 찜 해제 시트.
class _ManageFavoritesSheet extends StatelessWidget {
  final FavoritesStore favorites;

  const _ManageFavoritesSheet({required this.favorites});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: AnimatedBuilder(
          animation: favorites,
          builder: (context, _) {
            final artists = favorites.favoriteArtists;
            final concerts = favorites.favoriteConcerts;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Text(
                    '찜 관리',
                    style: TextStyle(fontSize: context.sp(16), fontWeight: FontWeight.w900),
                  ),
                ),
                const Divider(height: 1, thickness: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '선호 아티스트',
                          style: TextStyle(
                            fontSize: context.sp(13),
                            fontWeight: FontWeight.w900,
                            color: Colors.black.withValues(alpha: 0.4),
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (artists.isEmpty)
                          const _EmptyManageRow(text: '찜한 아티스트가 없습니다.')
                        else
                          ...artists.map(
                            (a) => _ManageListTile(
                              label: a.name,
                              imageUrl: a.profileImageUrl,
                              placeholderIcon: Icons.person_outline,
                              onRemove: () => favorites.removeArtist(a.name),
                            ),
                          ),
                        const SizedBox(height: 18),
                        Text(
                          '찜 공연',
                          style: TextStyle(
                            fontSize: context.sp(13),
                            fontWeight: FontWeight.w900,
                            color: Colors.black.withValues(alpha: 0.4),
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (concerts.isEmpty)
                          const _EmptyManageRow(text: '찜한 공연이 없습니다.')
                        else
                          ...concerts.map(
                            (c) => _ManageListTile(
                              label: c.name,
                              imageUrl: c.posterImageUrl,
                              onRemove: () => favorites.removeConcert(c.name),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ManageListTile extends StatelessWidget {
  final String label;
  final String imageUrl;
  final IconData placeholderIcon;
  final VoidCallback onRemove;

  const _ManageListTile({
    required this.label,
    required this.imageUrl,
    this.placeholderIcon = Icons.broken_image_outlined,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 40,
              height: 40,
              child: imageUrl.isEmpty
                  ? _ThumbPlaceholder(icon: placeholderIcon)
                  : Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                      errorBuilder: (context, error, stackTrace) =>
                          _ThumbPlaceholder(icon: placeholderIcon),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: context.sp(14), fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 18),
            color: Colors.black.withValues(alpha: 0.45),
          ),
        ],
      ),
    );
  }
}

class _EmptyManageRow extends StatelessWidget {
  final String text;

  const _EmptyManageRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: context.sp(12),
          color: Colors.black.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}
