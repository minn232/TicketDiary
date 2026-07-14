import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/news_model.dart';
import '../widgets/poster_background.dart';

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
    if (_controller.value < 0.85) return;

    final ctx = _pageKey.currentContext;
    if (ctx != null) {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final topLeft = box.localToGlobal(Offset.zero);
        final rect = topLeft & box.size;
        if (rect.contains(details.globalPosition)) {
          return;
        }
      }
    }

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

            final dimOpacity = lerpDouble(0.0, 0.80, t)!;

            final expandedOpacity = Curves.easeIn.transform(
              ((t - 0.20) / 0.80).clamp(0.0, 1.0),
            );
            final collapsedOpacity = 1.0 - expandedOpacity;

            return Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      color: Colors.white.withValues(alpha: dimOpacity),
                    ),
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
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapDown: _onBackgroundTap,
                    child: const SizedBox.expand(),
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

class _ExpandedNewsDetail extends StatelessWidget {
  final GlobalKey pageKey;
  final Animation<double> contentOpacity;
  final NewsModel news;

  const _ExpandedNewsDetail({
    required this.pageKey,
    required this.contentOpacity,
    required this.news,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: PosterBackground(imageUrl: news.imageUrl)),

        Positioned.fill(
          child: Container(color: Colors.black.withValues(alpha: 0.20)),
        ),

        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Center(
              child: FractionallySizedBox(
                widthFactor: 0.888,
                heightFactor: 0.888,
                child: Container(
                  key: pageKey,
                  constraints: const BoxConstraints(maxWidth: 520),
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
                  child: FadeTransition(
                    opacity: contentOpacity,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            news.concert,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            news.artist,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.black.withValues(alpha: 0.55),
                            ),
                          ),
                          const SizedBox(height: 14),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: double.infinity,
                              height: 140,
                              // 이미지가 없거나 로드에 실패하면 그라데이션
                              // 플레이스홀더로 폴백합니다.
                              child: PosterBackground(
                                imageUrl: news.articleImageUrl,
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Expanded(
                            child: SingleChildScrollView(
                              child: Text(
                                news.content.isEmpty
                                    ? '아직 등록된 소식 내용이 없습니다.'
                                    : news.content,
                                style: const TextStyle(
                                  fontSize: 14,
                                  height: 1.6,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
