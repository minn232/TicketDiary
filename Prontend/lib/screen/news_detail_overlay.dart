import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/news_model.dart';
import '../widgets/poster_background.dart';
import '../widgets/responsive_text.dart';

/// 소식 폴라로이드 카드를 누르면, "공연 전" 티켓과 동일한 방식으로 카드가
/// 화면 전체로 확장되며 소식 상세(포스터 + 줄글 기사)를 보여주는 오버레이.
///
/// 애니메이션/닫기 로직은 [ConcertBeforeOverlay]와 동일한 구조를 따르되,
/// 내부 콘텐츠만 포스트잇 그리드 대신 포스터 배경 + 기사 본문으로 대체합니다.
class NewsDetailOverlay extends StatefulWidget {
  /// 애니메이션 시작 위치/크기(눌린 카드의 전역 Rect)
  final Rect startRect;

  /// 축소된 상태에서 보여줄 카드 위젯(실제 카드와 동일한 UI를 넘겨주면 자연스럽게 보임)
  final Widget collapsedCard;

  final NewsModel news;

  const NewsDetailOverlay({
    super.key,
    required this.startRect,
    required this.collapsedCard,
    required this.news,
  });

  /// 다이어리/소식 화면 위에 오버레이를 띄우는 헬퍼.
  static Future<void> show(
    BuildContext context, {
    required Rect startRect,
    required Widget collapsedCard,
    required NewsModel news,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'news_detail_overlay',
      barrierColor: Colors.transparent,
      pageBuilder: (context, animation, secondaryAnimation) {
        return NewsDetailOverlay(
          startRect: startRect,
          collapsedCard: collapsedCard,
          news: news,
        );
      },
    );
  }

  @override
  State<NewsDetailOverlay> createState() => _NewsDetailOverlayState();
}

class _NewsDetailOverlayState extends State<NewsDetailOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _t;

  /// 상세 콘텐츠(포스터 위 흰 카드) 페이드 인
  late final Animation<double> _contentOpacity;

  /// 흰 카드 영역 "바깥"을 눌렀을 때만 닫히도록 판정하기 위한 key
  final GlobalKey _pageKey = GlobalKey();

  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );

    _t = CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic);

    _contentOpacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.55, 1.0, curve: Curves.easeOutCubic),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Rect _getRectForT(Size screen, double t) {
    final end = Rect.fromCenter(
      center: screen.center(Offset.zero),
      width: screen.width * 0.90,
      height: screen.height * 0.90,
    );
    return Rect.lerp(widget.startRect, end, t)!;
  }

  double _getRadiusForT(double t) {
    return lerpDouble(4, 18, t)!;
  }

  void _onBackgroundTap(TapDownDetails details) {
    _handleOutsideTap();
  }

  /// 카드 바깥(어두운 dim 영역) 또는 카드 안이지만 흰 카드가 아닌 자리
  /// (포스터가 비치는 여백)를 눌렀을 때 호출됩니다. 두 곳 모두 "닫기"만
  /// 하면 되므로 같은 로직을 공유합니다.
  void _handleOutsideTap() {
    if (_controller.value < 0.85) return;
    _close();
  }

  Future<void> _close() async {
    if (_isClosing) return;
    _isClosing = true;

    try {
      await _controller.reverse();
    } catch (_) {
      // route dispose 등으로 reverse가 중단될 수 있음
    }

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenSize = media.size;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _close();
      },
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _t.value;
            final rect = _getRectForT(screenSize, t);
            final radius = _getRadiusForT(t);

            final dimOpacity = lerpDouble(0.0, 0.40, t)!;

            final expandedOpacity = Curves.easeIn.transform(
              ((t - 0.20) / 0.80).clamp(0.0, 1.0),
            );
            final collapsedOpacity = 1.0 - expandedOpacity;

            return Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      color: Colors.black.withValues(alpha: dimOpacity),
                    ),
                  ),
                ),

                // 전체 탭 감지(페이지 바깥을 눌러야만 닫힘). 카드 콘텐츠보다
                // 먼저(=아래에) 둬야 합니다 — 위에 두면 translucent라도 탭
                // 제스처 경합(arena)에서 카드 안 인터랙티브 요소(공연장
                // 탭-지도 이동, 포스터 확대 등)와 이 감지기가 항상 같이
                // 경쟁하게 되어, 곧잘 이 감지기가 이겨서 카드 안 요소가
                // 눌리지 않는 문제가 있었습니다(concert_before/after_overlay와
                // 동일한 문제). 아래에 두면 카드 안 인터랙티브 요소가 있는
                // 자리는 그 요소가 먼저 히트되어 이 감지기까지 도달하지
                // 않고, 카드 바깥(진짜 빈 공간)만 이 감지기가 받습니다.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapDown: _onBackgroundTap,
                    child: const SizedBox.expand(),
                  ),
                ),

                Positioned.fromRect(
                  rect: rect,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Opacity(
                              opacity: collapsedOpacity,
                              child: widget.collapsedCard,
                            ),
                          ),
                        ),

                        Positioned.fill(
                          child: Opacity(
                            opacity: expandedOpacity,
                            child: _ExpandedNewsDetail(
                              pageKey: _pageKey,
                              contentOpacity: _contentOpacity,
                              news: widget.news,
                              onOutsideTap: _handleOutsideTap,
                            ),
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

class _ExpandedNewsDetail extends StatefulWidget {
  final GlobalKey pageKey;
  final Animation<double> contentOpacity;
  final NewsModel news;
  final VoidCallback onOutsideTap;

  const _ExpandedNewsDetail({
    required this.pageKey,
    required this.contentOpacity,
    required this.news,
    required this.onOutsideTap,
  });

  @override
  State<_ExpandedNewsDetail> createState() => _ExpandedNewsDetailState();
}

class _ExpandedNewsDetailState extends State<_ExpandedNewsDetail> {
  /// 포스터를 크게 보여주는 중인지. 작은 포스터를 누르면 true, 커진
  /// 포스터 바깥(여백)을 누르면 false로 돌아갑니다.
  bool _posterExpanded = false;

  /// 확대된 포스터의 확대/이동 상태. 더블탭으로 이 값을 직접 바꿔
  /// 확대·축소하고, 확대된 동안은 [InteractiveViewer]가 드래그로 이동을
  /// 처리합니다.
  final TransformationController _posterZoomController =
      TransformationController();

  /// 더블탭한 위치를 기준으로 확대해야 자연스러워서, onDoubleTapDown에서
  /// 좌표를 받아뒀다가 onDoubleTap에서 씁니다.
  TapDownDetails? _posterDoubleTapDetails;

  static const double _posterDoubleTapZoomScale = 2.5;

  void _handlePosterDoubleTapDown(TapDownDetails details) {
    _posterDoubleTapDetails = details;
  }

  void _handlePosterDoubleTap() {
    final isZoomedIn =
        _posterZoomController.value.getMaxScaleOnAxis() > 1.01;
    if (isZoomedIn) {
      _posterZoomController.value = Matrix4.identity();
      return;
    }
    final position = _posterDoubleTapDetails?.localPosition ?? Offset.zero;
    const scale = _posterDoubleTapZoomScale;
    _posterZoomController.value = Matrix4.identity()
      ..translateByDouble(
        -position.dx * (scale - 1),
        -position.dy * (scale - 1),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  void _collapsePoster() {
    setState(() => _posterExpanded = false);
    _posterZoomController.value = Matrix4.identity();
  }

  @override
  void dispose() {
    _posterZoomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final news = widget.news;
    return Stack(
      children: [
        Positioned.fill(child: PosterBackground(imageUrl: news.imageUrl)),

        // 흰 카드 바깥, 포스터가 비치는 여백을 누르면 닫힙니다. 이 레이어가
        // 화면 전체(카드 포함 영역)를 덮고 있지만, 실제 흰 카드는 이보다
        // 나중에(=위에) 그려져 먼저 히트되므로 카드 안 요소(공연장 탭 등)
        // 와는 경합하지 않습니다 — 카드가 차지하지 않는 자리만 이 감지기가
        // 받습니다.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOutsideTap,
            child: Container(color: Colors.white.withValues(alpha: 0.50)),
          ),
        ),

        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Center(
              child: FractionallySizedBox(
                // 카드를 기존보다 가로/세로 8% 더 크게(20% 키운 뒤 10% 축소 = 순증 8%)
                widthFactor: 0.888 * 1.08,
                heightFactor: 0.888 * 1.08,
                child: Container(
                  key: widget.pageKey,
                  constraints: const BoxConstraints(maxWidth: 562),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.10),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 18,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  // 카드 폭이 maxWidth(562)에 걸리기 전까지는 화면 폭에 맞춰
                  // 늘어나므로(FractionallySizedBox), 아이패드처럼 화면이
                  // 넓은 기기에서는 카드 자체가 아이폰보다 훨씬 커집니다.
                  // 안쪽 여백/간격/썸네일 크기가 고정 픽셀이면 그만큼
                  // 상대적으로 작아 보여서, 실제로 렌더링된 카드 폭 대비
                  // 비율(k)로 스케일링합니다. 350은 아이폰 계열에서 이
                  // 카드가 보통 실제로 차지하는 폭에 맞춘 기준값이라,
                  // 아이폰에서는 k≈1(기존과 거의 동일)입니다.
                  child: LayoutBuilder(
                    builder: (context, cardConstraints) {
                      final k = cardConstraints.maxWidth / 350.0;
                      return FadeTransition(
                        opacity: widget.contentOpacity,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            22 * k,
                            19 * k,
                            22 * k,
                            19 * k,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                news.concert,
                                style: TextStyle(
                                  fontSize: context.sp(19),
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              SizedBox(height: 4 * k),
                              Text(
                                news.artist,
                                style: TextStyle(
                                  fontSize: context.sp(14),
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black.withValues(alpha: 0.55),
                                ),
                              ),
                              SizedBox(height: 15 * k),
                              GestureDetector(
                                onTap: () =>
                                    setState(() => _posterExpanded = true),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8 * k),
                                  child: SizedBox(
                                    width: double.infinity,
                                    height: 151 * k,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        // 이미지가 없거나 로드에 실패하면
                                        // 그라데이션 플레이스홀더로
                                        // 폴백합니다.
                                        PosterBackground(
                                          imageUrl: news.articleImageUrl,
                                        ),
                                        // 눌러서 크게 볼 수 있다는 힌트 아이콘.
                                        Positioned(
                                          right: 8 * k,
                                          bottom: 8 * k,
                                          child: Container(
                                            padding: EdgeInsets.all(5 * k),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.45,
                                              ),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              Icons.zoom_in,
                                              size: 16 * k,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(height: 15 * k),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _NewsContentBody(news: news, scale: k),
                                      SizedBox(height: 18 * k),
                                      _TicketingVendorButtons(
                                        ticketingLinks: news.ticketingLinks,
                                        scale: k,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),

        // 포스터를 크게 보여주는 레이어. 작은 포스터를 누르면 나타납니다.
        // 흰 카드보다 나중에(=위에) 그려지므로, 카드 안 다른 요소와 탭
        // 제스처가 경합할 걱정 없이 항상 이 레이어가 먼저 탭을 받습니다.
        IgnorePointer(
          ignoring: !_posterExpanded,
          child: AnimatedOpacity(
            opacity: _posterExpanded ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: Container(
              color: Colors.black.withValues(alpha: 0.88),
              child: Stack(
                children: [
                  // 포스터 바깥(여백)을 누르면 닫히는 감지기. 포스터
                  // 자체(아래 SafeArea 안)보다 먼저(=아래에) 둬서, 포스터
                  // 위 더블탭/드래그 제스처와 경합하지 않고 포스터가
                  // 차지하지 않는 자리만 이 감지기가 받습니다 — 배경
                  // 감지기를 카드보다 뒤에 두는 것과 같은 원칙입니다.
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _collapsePoster,
                    ),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      // InteractiveViewer는 (Center 밑에서 그냥 두면) 자기
                      // 자식인 포스터의 원래(축소 배율) 크기로 줄어들어,
                      // 뷰포트 자체가 그 작은 박스에 갇혀버립니다 — 그
                      // 안에서만 확대/이동이 되니 "확대해도 딱 그 자리
                      // 안에서만 커 보이는" 문제가 있었습니다. SizedBox.expand
                      // 로 뷰포트 자체를 이 자리(패딩 뺀 화면 전체)만큼
                      // 강제로 채워서, 확대했을 때 포스터의 원래 그리드
                      // 크기와 무관하게 화면 전체를 자유롭게 씁니다. 확대
                      // 전(1배) 모습은 안쪽 Center가 그대로 유지합니다.
                      child: SizedBox.expand(
                        child: GestureDetector(
                          onDoubleTapDown: _handlePosterDoubleTapDown,
                          onDoubleTap: _handlePosterDoubleTap,
                          child: InteractiveViewer(
                            transformationController: _posterZoomController,
                            minScale: 1.0,
                            maxScale: _posterDoubleTapZoomScale * 2,
                            child: Center(child: _buildLargePoster(news)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 원본 비율 그대로(잘리지 않게) 크게 보여주는 포스터. 작은 썸네일과
  /// 달리 [BoxFit.contain] + 불투명도 1.0을 씁니다([PosterBackground]는
  /// 항상 cover+0.85 불투명도라 재사용하지 않습니다).
  Widget _buildLargePoster(NewsModel news) {
    final url = news.articleImageUrl;
    if (url.isEmpty) {
      return const AspectRatio(
        aspectRatio: 3 / 4,
        child: ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          child: PosterGradientPlaceholder(),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        url,
        fit: BoxFit.contain,
        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
        errorBuilder: (context, error, stackTrace) => const AspectRatio(
          aspectRatio: 3 / 4,
          child: PosterGradientPlaceholder(),
        ),
      ),
    );
  }
}

// [백엔드 수정]
// KOPIS가 실제로 준 예매처만(ticketingLinks) 버튼으로 보여주고, 눌렀을 때
// 진짜 예매 링크로 이동. externalApplication 모드로 열어서, 그 사이트가
// 앱 링크(Android App Links/iOS Universal Links)를 지원하면 자동으로 해당
// 예매처 앱으로 연결됨(설치 안 돼있으면 브라우저 폴백) - 예매처별 커스텀
// 딥링크 스킴은 알아내기 fragile해서 안 씀. ticketingLinks가 비어있으면
// 섹션 자체를 숨김.
class _TicketingVendorButtons extends StatelessWidget {
  const _TicketingVendorButtons({required this.ticketingLinks, required this.scale});

  final Map<String, String>? ticketingLinks;

  /// 카드 실제 렌더링 폭 기준 스케일(자세한 설명은 [_ExpandedNewsDetailState.build] 참고).
  final double scale;

  static const Map<String, String> _vendorLabels = {
    'INTERPARK': '인터파크',
    'YES24': '예스24',
    'TICKETLINK': '티켓링크',
    'MELON': '멜론티켓',
  };

  Future<void> _openVendor(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final links = ticketingLinks;
    if (links == null || links.isEmpty) return const SizedBox.shrink();

    final k = scale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 1, color: Colors.black.withValues(alpha: 0.08)),
        SizedBox(height: 14 * k),
        Text(
          '예매처 바로가기',
          style: TextStyle(
            fontSize: context.sp(13),
            fontWeight: FontWeight.w800,
            color: Colors.black.withValues(alpha: 0.55),
          ),
        ),
        SizedBox(height: 8 * k),
        Wrap(
          spacing: 8 * k,
          runSpacing: 8 * k,
          children: [
            for (final entry in links.entries)
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.symmetric(
                    horizontal: 14 * k,
                    vertical: 8 * k,
                  ),
                  side: BorderSide(color: Colors.black.withValues(alpha: 0.2)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20 * k),
                  ),
                ),
                onPressed: () => _openVendor(entry.value),
                child: Text(
                  _vendorLabels[entry.key] ?? entry.key,
                  style: TextStyle(
                    fontSize: context.sp(13),
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 소식 상세 본문. [NewsModel.contentTop](출연진/공연 기간 등) 다음에
/// 공연장 이름(탭하면 지도로 이동)을, 그다음에
/// [NewsModel.contentBottom](티케팅 날짜 등)을 순서대로 보여줍니다. 공연장
/// 줄만 줄글 텍스트가 아니라 탭 가능한 위젯이라 이렇게 세 조각으로
/// 나눠 그립니다.
class _NewsContentBody extends StatelessWidget {
  const _NewsContentBody({required this.news, required this.scale});

  final NewsModel news;

  /// 카드 실제 렌더링 폭 기준 스케일(자세한 설명은 [_ExpandedNewsDetailState.build] 참고).
  final double scale;

  @override
  Widget build(BuildContext context) {
    final hasVenue = news.venue != null && news.venue!.isNotEmpty;
    if (news.contentTop.isEmpty && news.contentBottom.isEmpty && !hasVenue) {
      return Text(
        '아직 등록된 소식 내용이 없습니다.',
        style: TextStyle(
          fontSize: context.sp(15),
          height: 1.6,
          color: Colors.black87,
        ),
      );
    }

    final textStyle = TextStyle(
      fontSize: context.sp(15),
      height: 1.6,
      color: Colors.black87,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (news.contentTop.isNotEmpty) Text(news.contentTop, style: textStyle),
        if (hasVenue) ...[
          if (news.contentTop.isNotEmpty) SizedBox(height: 4 * scale),
          _VenueRow(venue: news.venue!, scale: scale),
          if (news.contentBottom.isNotEmpty) SizedBox(height: 4 * scale),
        ],
        if (news.contentBottom.isNotEmpty)
          Text(news.contentBottom, style: textStyle),
      ],
    );
  }
}

/// 공연장 이름 한 줄. 누르면 지도 앱(카카오맵/네이버지도) 선택 시트가
/// 뜨고, 고른 앱에서 이 이름으로 검색합니다.
///
/// 실제 도로명주소는 앱 어디에도 없습니다(KOPIS가 공연장 "이름"만 주고,
/// 백엔드도 주소/좌표를 따로 수집하지 않음) — 그래서 정확한 좌표 대신
/// 공연장 이름으로 지도 검색 링크를 엽니다. 대부분의 공연장은 지도
/// 앱에 등록돼 있어 이름 검색만으로도 잘 찾아집니다.
class _VenueRow extends StatelessWidget {
  const _VenueRow({required this.venue, required this.scale});

  final String venue;

  /// 카드 실제 렌더링 폭 기준 스케일(자세한 설명은 [_ExpandedNewsDetailState.build] 참고).
  final double scale;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showMapPicker(context, venue),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 2 * scale),
        child: Row(
          children: [
            // 다른 줄(출연진/공연 기간/티케팅 날짜)과 같은 스타일의 라벨.
            Text(
              '공연장  ',
              style: TextStyle(
                fontSize: context.sp(15),
                height: 1.6,
                color: Colors.black87,
              ),
            ),
            Icon(
              Icons.location_on_outlined,
              size: context.sp(15),
              color: Colors.black.withValues(alpha: 0.55),
            ),
            SizedBox(width: 3 * scale),
            // [백엔드 수정]
            // TextDecoration.underline은 띄어쓰기 부분에서 밑줄이 살짝 끊겨
            // 떠 보이는 문제가 있어(폰트 글리프별로 그려짐), 텍스트 전체
            // 아래에 실선 테두리를 긋는 방식으로 바꿔 연결된 한 줄로 보이게 함.
            Flexible(
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.black.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                ),
                padding: const EdgeInsets.only(bottom: 1),
                child: Text(
                  venue,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.sp(13),
                    fontWeight: FontWeight.w700,
                    color: Colors.black.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _MapProvider { kakao, naver }

/// "카카오맵/네이버지도 중 선택" 바텀시트를 띄우고, 고른 지도 앱의 검색
/// 링크를 엽니다. 두 서비스 모두 앱이 설치돼 있으면 앱으로, 아니면
/// 웹으로 열리는 공식 웹 검색 링크 형식을 씁니다(별도 API 키/앱 등록
/// 없이 동작).
Future<void> _showMapPicker(BuildContext context, String venue) async {
  final choice = await showModalBottomSheet<_MapProvider>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '지도 앱 선택',
                style: TextStyle(
                  fontSize: context.sp(15),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('카카오맵으로 보기'),
            onTap: () => Navigator.of(context).pop(_MapProvider.kakao),
          ),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('네이버지도로 보기'),
            onTap: () => Navigator.of(context).pop(_MapProvider.naver),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (choice == null) return;

  final query = Uri.encodeComponent(venue);
  final uri = switch (choice) {
    _MapProvider.kakao => Uri.parse('https://map.kakao.com/link/search/$query'),
    _MapProvider.naver => Uri.parse('https://map.naver.com/v5/search/$query'),
  };
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
