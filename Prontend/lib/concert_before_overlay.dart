import 'dart:ui';

import 'package:flutter/material.dart';

import 'widgets/concert_before_page_contents.dart';

/// 다이어리 화면 위에 "공연 전" 상세를 오버레이로 띄우는 위젯.
///
/// 요구사항 요약
/// - 다이어리 화면 위에 그대로 그려짐(새 페이지로 완전히 전환 X)
/// - 공연 전 티켓을 누르면, 티켓(시작 Rect)이 전체 화면으로 자연스럽게 확장
/// - 배경은 공연 포스터 느낌(placeholder)
/// - 그 위에 "메인 페이지"(흰 종이) + 포스트잇들이 서서히(Fade) 나타남
/// - 닫기: 포스트잇이 있는 메인 페이지 "바깥"(어두운/불투명 영역)을 눌렀을 때만 닫힘
///
/// NOTE
/// - 포스터 이미지는 현재 샘플 그라데이션/텍스트로 되어 있음.
///   실제 포스터를 쓰고 싶으면 [_PosterBackground]를 AssetImage/NetworkImage 등으로 교체하면 됩니다.
class ConcertBeforeOverlay extends StatefulWidget {
  /// 애니메이션 시작 위치/크기 (다이어리에서 눌린 티켓의 전역 Rect)
  final Rect startRect;

  /// 축소된 상태에서 보여줄 티켓 위젯(다이어리 티켓과 동일한 UI를 넘겨주면 더 자연스럽게 보임)
  final Widget collapsedTicket;

  /// 공연 제목(페이지/포스트잇에 노출)
  final String concertTitle;

  const ConcertBeforeOverlay({
    super.key,
    required this.startRect,
    required this.collapsedTicket,
    required this.concertTitle,
  });

  /// 다이어리 위에 오버레이를 띄우는 헬퍼.
  static Future<void> show(
    BuildContext context, {
    required Rect startRect,
    required Widget collapsedTicket,
    required String concertTitle,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false, // 반드시 우리 로직(페이지 밖 탭)으로만 닫히도록
      barrierLabel: 'concert_before_overlay',
      barrierColor: Colors
          .transparent, // 다이어리 화면이 비치도록 투명. 실제 dim은 내부에서 애니메이션으로 구현
      pageBuilder: (context, animation, secondaryAnimation) {
        return ConcertBeforeOverlay(
          startRect: startRect,
          collapsedTicket: collapsedTicket,
          concertTitle: concertTitle,
        );
      },
    );
  }

  @override
  State<ConcertBeforeOverlay> createState() => _ConcertBeforeOverlayState();
}

class _ConcertBeforeOverlayState extends State<ConcertBeforeOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _t;

  /// 포스트잇(콘텐츠) 페이드 인
  late final Animation<double> _postItOpacity;

  /// 메인 페이지 영역(흰 종이) 바깥 탭으로만 닫기 위한 key
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

    // 확장이 어느 정도 끝나갈 때(후반)에 포스트잇이 서서히 나타나도록
    _postItOpacity = CurvedAnimation(
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
    // 최종은 화면의 90% 크기(=10% 축소)로 중앙에 배치.
    // - 포스터가 들어갈 "바깥" 영역을 조금 더 크게 보이게 하기 위함
    // - 내부 메인 페이지(흰 종이)는 별도로 80% 크기 느낌을 유지하도록 아래에서 추가로 제한합니다.
    final end = Rect.fromCenter(
      center: screen.center(Offset.zero),
      width: screen.width * 0.90,
      height: screen.height * 0.90,
    );
    return Rect.lerp(widget.startRect, end, t)!;
  }

  double _getRadiusForT(double t) {
    // 시작은 티켓 모서리 둥글게(기존 티켓과 비슷)
    // 끝은 "모달"처럼 보이도록 라운드를 약간 유지
    return lerpDouble(10, 18, t)!;
  }

  void _onBackgroundTap(TapDownDetails details) {
    // 애니메이션 중에는 실수로 닫히지 않도록 어느 정도 진행 이후만 허용
    if (_controller.value < 0.85) return;

    // "메인 페이지(흰 종이)" 안을 눌렀으면 닫히면 안 됨
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

          // 다이어리 화면 dim(불투명하게)
          // - 확장 초반에는 더 약하게, 확장 후반에는 더 강하게
              // 요청: 바깥 여백은 다이어리 화면을 80% 불투명(강하게 dim)
              final dimOpacity = lerpDouble(0.0, 0.80, t)!;

          // 축소 티켓 -> 확장 콘텐츠로 자연스럽게 전환
          final expandedOpacity = Curves.easeIn.transform(((t - 0.20) / 0.80).clamp(0.0, 1.0));
          final collapsedOpacity = 1.0 - expandedOpacity;

          return Stack(
            children: [
              // 아래: 다이어리 화면을 어둡게(불투명하게) 만드는 레이어
              Positioned.fill(
                child: IgnorePointer(
                  // 요청: 다이어리 화면을 "검정"이 아니라 "하얀색"으로 불투명하게(화이트 헤이즈)
                  child: Container(color: Colors.white.withValues(alpha: dimOpacity)),
                ),
              ),

              // 확장되는 티켓(시작Rect -> 화면 전체)
              Positioned.fromRect(
                rect: rect,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      // (1) 축소 상태에서 보이던 티켓 UI
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Opacity(
                            opacity: collapsedOpacity,
                            child: widget.collapsedTicket,
                          ),
                        ),
                      ),

                      // (2) 확장 상태의 공연 전 화면(포스터 배경 + 메인 페이지 + 포스트잇)
                      Positioned.fill(
                        child: Opacity(
                          opacity: expandedOpacity,
                          child: _ExpandedConcertBefore(
                            pageKey: _pageKey,
                            postItOpacity: _postItOpacity,
                            concertTitle: widget.concertTitle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 전체 탭 감지(페이지 바깥을 눌러야만 닫힘)
              // - 최상단에 둬야, 확장된 티켓(전체 화면)을 덮고 있어도 탭을 확실히 받을 수 있습니다.
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

class _ExpandedConcertBefore extends StatelessWidget {
  final GlobalKey pageKey;
  final Animation<double> postItOpacity;
  final String concertTitle;

  const _ExpandedConcertBefore({
    required this.pageKey,
    required this.postItOpacity,
    required this.concertTitle,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: _PosterBackground()),

        // 포스터를 조금 어둡게 해서 페이지가 더 잘 보이게(이 영역이 "불투명한 부분" 역할)
        Positioned.fill(
          child: Container(color: Colors.black.withValues(alpha: 0.20)),
        ),

        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Center(
              child: FractionallySizedBox(
                // 오버레이(포스터)는 화면의 90%로 커졌고,
                // 내부 메인 페이지는 화면의 80% 크기 느낌을 유지해야 하므로
                // 0.80 / 0.90 = 0.888.. 비율로 제한
                widthFactor: 0.888,
                heightFactor: 0.888,
                child: Container(
                  key: pageKey,
                  constraints: const BoxConstraints(maxWidth: 520),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.black.withValues(alpha: 0.10), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 18,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                         child: Padding(
                         padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                         child: ConcertBeforePageContents(
                           concertTitle: concertTitle,
                           postItOpacity: postItOpacity,
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

class _PosterBackground extends StatelessWidget {
  const _PosterBackground();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1F1C2C),
            const Color(0xFF928DAB),
          ],
        ),
      ),
      child: Center(
        child: Text(
          'CONCERT\nPOSTER',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 44,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
            color: Colors.white.withValues(alpha: 0.12),
          ),
        ),
      ),
    );
  }
}



