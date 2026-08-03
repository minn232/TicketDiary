import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/ticket_info.dart';
import '../widgets/concert_after_page_contents.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/poster_background.dart';

/// 다이어리 화면 위에 "공연 후" 상세를 오버레이로 띄우는 위젯.
///
/// [ConcertBeforeOverlay]와 정확히 같은 등장 로직(같은 지속 시간·곡선,
/// 같은 시작Rect→화면 확장, 같은 dim/크로스페이드, 같은 "바깥 탭으로만
/// 닫기")을 그대로 따릅니다. 다른 점은 확장된 콘텐츠뿐입니다 — "공연 전"은
/// 포스터 배경 위에 흰 카드를 띄우고, "공연 후"는 원래 디자인대로 다이어리
/// 종이색 카드 위에 [ConcertAfterPageContents](사진/소감/도장/셋리스트
/// 2x2 카드)를 띄웁니다.
class ConcertAfterOverlay extends StatefulWidget {
  /// 애니메이션 시작 위치/크기 (다이어리에서 눌린 티켓의 전역 Rect)
  final Rect startRect;

  /// 축소된 상태에서 보여줄 티켓 위젯(다이어리 티켓과 동일한 UI를 넘겨주면 더 자연스럽게 보임)
  final Widget collapsedTicket;

  /// 공연 제목(헤더에 노출)
  final String concertTitle;

  /// 스캔된 티켓 정보(공연장/날짜/사진/소감 등). 없으면 placeholder가 표시됩니다.
  final TicketInfo? ticketInfo;

  const ConcertAfterOverlay({
    super.key,
    required this.startRect,
    required this.collapsedTicket,
    required this.concertTitle,
    this.ticketInfo,
  });

  /// 다이어리 위에 오버레이를 띄우는 헬퍼.
  static Future<void> show(
    BuildContext context, {
    required Rect startRect,
    required Widget collapsedTicket,
    required String concertTitle,
    TicketInfo? ticketInfo,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false, // 반드시 우리 로직(페이지 밖 탭)으로만 닫히도록
      barrierLabel: 'concert_after_overlay',
      barrierColor:
          Colors.transparent, // 다이어리 화면이 비치도록 투명. 실제 dim은 내부에서 애니메이션으로 구현
      pageBuilder: (context, animation, secondaryAnimation) {
        return ConcertAfterOverlay(
          startRect: startRect,
          collapsedTicket: collapsedTicket,
          concertTitle: concertTitle,
          ticketInfo: ticketInfo,
        );
      },
    );
  }

  @override
  State<ConcertAfterOverlay> createState() => _ConcertAfterOverlayState();
}

class _ConcertAfterOverlayState extends State<ConcertAfterOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _t;

  /// 2x2 카드(콘텐츠) 페이드 인
  late final Animation<double> _postItOpacity;

  /// 카드(다이어리 종이) 바깥 탭으로만 닫기 위한 key
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

    // 확장이 어느 정도 끝나갈 때(후반)에 카드 내용이 서서히 나타나도록
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

  /// [ConcertBeforeOverlay._getRectForT]와 동일한 기준(SafeArea로 줄어든
  /// 영역, diaryAspectRatio, 10% 확대)으로 계산합니다.
  Rect _getRectForT(Size screen, EdgeInsets safePadding, double t) {
    const ratio = DiaryPageFrame.diaryAspectRatio;
    final safeWidth = screen.width - safePadding.left - safePadding.right;
    final safeHeight = screen.height - safePadding.top - safePadding.bottom;

    double endWidth = safeWidth;
    double endHeight = endWidth / ratio;
    if (endHeight > safeHeight) {
      endHeight = safeHeight;
      endWidth = endHeight * ratio;
    }
    endWidth *= 1.1;
    endHeight *= 1.1;
    final safeCenter = Offset(
      safePadding.left + safeWidth / 2,
      safePadding.top + safeHeight / 2,
    );
    final end = Rect.fromCenter(
      center: safeCenter,
      width: endWidth,
      height: endHeight,
    );
    return Rect.lerp(widget.startRect, end, t)!;
  }

  double _getRadiusForT(double t) {
    return lerpDouble(10, 18, t)!;
  }

  void _onBackgroundTap(TapDownDetails details) {
    // 애니메이션 중에는 실수로 닫히지 않도록 어느 정도 진행 이후만 허용
    if (_controller.value < 0.85) return;

    // "카드(다이어리 종이)" 안을 눌렀으면 닫히면 안 됨
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
            final rect = _getRectForT(screenSize, media.padding, t);
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
                // 제스처 경합(arena)에서 카드 안 버튼(InkWell 등)과 이
                // 감지기가 항상 같이 경쟁하게 되어, 곧잘 이 감지기가 이겨서
                // 카드 안 버튼이 눌리지 않는 문제가 있었습니다. 아래에 두면
                // 카드 안 인터랙티브 요소가 있는 자리는 그 요소가 먼저
                // 히트되어 이 감지기까지 도달하지 않고(경합 자체가 없음),
                // 카드 바깥(진짜 빈 공간)만 이 감지기가 받습니다.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapDown: _onBackgroundTap,
                    child: const SizedBox.expand(),
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

                        // (2) 확장 상태의 공연 후 화면(다이어리 종이 카드 + 2x2 카드)
                        Positioned.fill(
                          child: Opacity(
                            opacity: expandedOpacity,
                            child: _ExpandedConcertAfter(
                              pageKey: _pageKey,
                              postItOpacity: _postItOpacity,
                              concertTitle: widget.concertTitle,
                              ticketInfo: widget.ticketInfo,
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

class _ExpandedConcertAfter extends StatelessWidget {
  final GlobalKey pageKey;
  final Animation<double> postItOpacity;
  final String concertTitle;
  final TicketInfo? ticketInfo;

  const _ExpandedConcertAfter({
    required this.pageKey,
    required this.postItOpacity,
    required this.concertTitle,
    this.ticketInfo,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Center(
          child: Container(
            key: pageKey,
            constraints: const BoxConstraints(maxWidth: 562),
            // 포스터 배경(아래)이 이 카드의 둥근 모서리 밖으로 삐져나오지
            // 않도록 clip합니다.
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              // DiaryPageFrame.pageColor 기본값과 동일한 다이어리 종이색.
              color: const Color(0xFFF4F1E1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.black.withValues(alpha: 0.10),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 18,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Stack(
              children: [
                // 공연 포스터를 카드 배경 전체(카드와 같은 둥근 모서리)에
                // 살짝 투명하게 겹칩니다.
                Positioned.fill(
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: 0.4,
                      child: PosterBackground(
                        imageUrl: ticketInfo?.posterImageUrl,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 20, 18),
                  child: ConcertAfterPageContents(
                    concertTitle: concertTitle,
                    ticketInfo: ticketInfo,
                    postItOpacity: postItOpacity,
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
