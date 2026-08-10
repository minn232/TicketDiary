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

/// 설정 > 선호 아티스트 / 찜 공연 설정 화면
///
/// - 검색창에 타이핑하면(별도 검색 버튼 없이) 잠깐 멈출 때마다 자동으로
///   백엔드(KOPIS 실시간 검색)에서 아티스트/공연을 찾아 아래에 보여줍니다.
/// - 결과 카드를 누르면 찜 토글되며, 이 찜 목록은 [FavoritesStore]를 통해
///   기기 로컬과 서버(`/social/artists`, `/social/concerts`) 양쪽에 저장되어
///   소식 탭 피드 생성에 사용됩니다.
/// - 상단 "관리" 버튼으로 현재 찜한 아티스트/공연을 한눈에 보고 해제할 수 있습니다.
class FavoritePinnedSettingsScreen extends StatefulWidget {
  const FavoritePinnedSettingsScreen({super.key});

  @override
  State<FavoritePinnedSettingsScreen> createState() =>
      _FavoritePinnedSettingsScreenState();
}

class _FavoritePinnedSettingsScreenState
    extends State<FavoritePinnedSettingsScreen> {
  final ArtistSearchService _artistSearchService = BackendArtistSearchService();
  final ConcertSearchService _concertSearchService =
      BackendConcertSearchService();
  final FavoritesStore _favorites = FavoritesStore.instance;

  final TextEditingController _artistQueryController = TextEditingController();
  final TextEditingController _concertQueryController = TextEditingController();

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
    return DiaryPageFrame(
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.settings),
      child: Padding(
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
                  onBack: () => Navigator.pop(context),
                  onManage: _openManageSheet,
                ),
                const Divider(height: 1, thickness: 1),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, viewport) {
                      const padding = 16.0;
                      return SingleChildScrollView(
                        padding: const EdgeInsets.all(padding),
                        child: ConstrainedBox(
                          // 내용이 화면보다 짧을 때, 아래에만 여백이 몰리는
                          // 대신 두 섹션 사이/앞뒤로 균등하게 나뉘도록
                          // 최소 높이를 뷰포트 전체로 잡습니다. 내용이 더
                          // 길어지면(검색 결과 등) 자연스럽게 스크롤됩니다.
                          constraints: BoxConstraints(
                            minHeight: viewport.maxHeight - padding * 2,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const _SectionTitle('선호 아티스트'),
                                  const SizedBox(height: 10),
                                  _SearchField(
                                    controller: _artistQueryController,
                                    hintText: '아티스트 이름 검색',
                                  ),
                                  const SizedBox(height: 14),
                                  _SearchResultsRow<ArtistModel>(
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
                                ],
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const _SectionTitle('찜 공연'),
                                  const SizedBox(height: 10),
                                  _SearchField(
                                    controller: _concertQueryController,
                                    hintText: '공연 이름 검색',
                                  ),
                                  const SizedBox(height: 14),
                                  _SearchResultsRow<ConcertModel>(
                                    items: _concertResults,
                                    searching: _concertSearching,
                                    statusText: _concertStatusText,
                                    nameOf: (c) => c.name,
                                    imageUrlOf: (c) => c.posterImageUrl,
                                    isFavoritedOf: (c) =>
                                        _favorites.isConcertFavorited(c.name),
                                    onTap: (c) => _favorites.toggleConcert(c),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final VoidCallback onManage;

  const _TopBar({
    required this.title,
    required this.onBack,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
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

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: context.sp(13),
        fontWeight: FontWeight.w900,
        color: Colors.black.withValues(alpha: 0.35),
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

/// 검색 결과를 가로로 보여주는 목록. 3개까지는 한 화면에 딱 맞게 채우고,
/// 그보다 많으면 가로 스크롤이 가능합니다(카드 크기는 항상 동일하게 유지).
class _SearchResultsRow<T> extends StatelessWidget {
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

  const _SearchResultsRow({
    required this.items,
    required this.searching,
    required this.statusText,
    required this.nameOf,
    required this.imageUrlOf,
    this.placeholderIcon = Icons.broken_image_outlined,
    required this.isFavoritedOf,
    required this.onTap,
  });

  static const _visibleCount = 3;
  static const _spacing = 12.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth =
            (constraints.maxWidth - _spacing * (_visibleCount - 1)) /
            _visibleCount;
        final rowHeight = cardWidth + 34;

        if (searching) {
          return SizedBox(
            height: rowHeight,
            child: const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.brown,
                ),
              ),
            ),
          );
        }

        if (items.isEmpty) {
          return SizedBox(
            height: rowHeight,
            child: Center(
              child: Text(
                statusText,
                style: TextStyle(
                  fontSize: context.sp(12),
                  color: Colors.black.withValues(alpha: 0.3),
                ),
              ),
            ),
          );
        }

        return SizedBox(
          height: rowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: items.length,
            separatorBuilder: (context, index) =>
                const SizedBox(width: _spacing),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: cardWidth,
                child: _ThumbCard(
                  label: nameOf(item),
                  imageUrl: imageUrlOf(item),
                  placeholderIcon: placeholderIcon,
                  favorited: isFavoritedOf(item),
                  onTap: () => onTap(item),
                ),
              );
            },
          ),
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
