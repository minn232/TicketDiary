import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/ticket_info.dart';
import '../widgets/concert_after_page_contents.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/poster_background.dart';
import '../widgets/responsive_text.dart';

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

  /// 오버레이 안(사진 추가/소감 작성)에서 [ticketInfo]가 갱신될 때마다
  /// 호출됩니다. 호출자가 다이어리 화면의 원본 [TicketData.info]를 같이
  /// 갱신해야, 오버레이를 닫은 뒤에도(앱 재시작 없이) 바로 최신 내용이
  /// 보입니다.
  final ValueChanged<TicketInfo>? onTicketInfoChanged;

  /// 탭한 순간 다이어리 리스트에서 쓰이던 [DiaryFrameScale] 배율.
  //
  // [백엔드 수정]
  // showGeneralDialog는 DiaryPageFrame 바깥의 새 라우트라 안에서
  // DiaryFrameScale을 못 찾고 화면 전체 폭 기준으로 폴백함
  // 탭 시점의 배율을 그대로 넘겨받아 오버레이 안에서도 동일하게 사용.
  final double frameScale;

  const ConcertAfterOverlay({
    super.key,
    required this.startRect,
    required this.collapsedTicket,
    required this.concertTitle,
    required this.frameScale,
    this.ticketInfo,
    this.onTicketInfoChanged,
  });

  /// 다이어리 위에 오버레이를 띄우는 헬퍼.
  static Future<void> show(
    BuildContext context, {
    required Rect startRect,
    required Widget collapsedTicket,
    required String concertTitle,
    required double frameScale,
    TicketInfo? ticketInfo,
    ValueChanged<TicketInfo>? onTicketInfoChanged,
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
          frameScale: frameScale,
          ticketInfo: ticketInfo,
          onTicketInfoChanged: onTicketInfoChanged,
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

  // [백엔드 수정]
  // 축소 티켓 <-> 확장 콘텐츠 크로스페이드 투명도를 매 프레임 double로
  // 계산해서 매 프레임 다시 빌드되던걸 Animation<double>로 미리 만들어두고
  // FadeTransition으로 씌우면 프레임마다 투명도만 갱신.
  late final Animation<double> _expandedOpacity;
  late final Animation<double> _collapsedOpacity;

  bool _isClosing = false;

  // [백엔드 수정]
  // 두 손가락 오므리기(핀치 인)로 오버레이를 닫는 기능.
  // Listener로 직접 두 손가락 사이 거리를 계산.
  final Map<int, Offset> _pinchPointers = {};
  double? _pinchStartDistance;
  bool _pinchTriggered = false;

  double _pinchCurrentDistance() {
    final points = _pinchPointers.values.toList();
    return (points[0] - points[1]).distance;
  }

  void _onPinchPointerDown(PointerDownEvent event) {
    _pinchPointers[event.pointer] = event.position;
    if (_pinchPointers.length == 2) {
      _pinchStartDistance = _pinchCurrentDistance();
      _pinchTriggered = false;
    } else {
      _pinchStartDistance = null;
    }
  }

  void _onPinchPointerMove(PointerMoveEvent event) {
    if (!_pinchPointers.containsKey(event.pointer)) return;
    _pinchPointers[event.pointer] = event.position;
    final start = _pinchStartDistance;
    if (_pinchPointers.length != 2 || start == null || _pinchTriggered) {
      return;
    }
    // 다 펼쳐진 뒤에만 반응(펼쳐지는 도중엔 무시)
    if (_controller.value < 0.95) return;
    // 시작 거리 대비 30% 이상 오므라들면 닫기로 간주
    if (_pinchCurrentDistance() / start < 0.7) {
      _pinchTriggered = true;
      _close();
    }
  }

  void _onPinchPointerEnd(PointerEvent event) {
    _pinchPointers.remove(event.pointer);
    if (_pinchPointers.length < 2) {
      _pinchStartDistance = null;
    }
  }

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

    // [백엔드 수정]
    // 중간 지점 근처 아주 짧은 구간(약 8%)에서만 빠르게 바뀌도록 좁혀서,
    // 겹쳐 보이는 구간을 거의 없애고 스위치되는 것처럼 보이게 함.
    _expandedOpacity = CurvedAnimation(
      parent: _t,
      curve: const Interval(0.46, 0.54, curve: Curves.easeInOut),
    );
    _collapsedOpacity = _expandedOpacity.drive(
      Tween<double>(begin: 1.0, end: 0.0),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// [ConcertBeforeOverlay._endRect]와 동일한 기준(SafeArea로 줄어든
  /// 영역, diaryAspectRatio, 10% 확대)으로 계산합니다.
  Rect _endRect(Size screen, EdgeInsets safePadding) {
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
    return Rect.fromCenter(
      center: safeCenter,
      width: endWidth,
      height: endHeight,
    );
  }

  Rect _getRectForT(Rect end, double t) {
    return Rect.lerp(widget.startRect, end, t)!;
  }

  double _getRadiusForT(double t) {
    return lerpDouble(10, 18, t)!;
  }

  /// 카드 바깥(어두운 dim 영역) 또는 카드 안이지만 포스트잇이 아닌 자리
  /// (헤더/안내 문구/포스터가 비치는 여백)를 눌렀을 때 호출됩니다. 두 곳
  /// 모두 "닫기"만 하면 되므로 같은 로직을 공유합니다.
  void _handleOutsideTap() {
    // 애니메이션 중에는 실수로 닫히지 않도록 어느 정도 진행 이후만 허용
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
    final end = _endRect(screenSize, media.padding);

    // [백엔드 수정]
    // 두 레이어의 실제 콘텐츠를 여기서 한 번만 만들어서 넘김.
    final collapsedLayer = Positioned.fill(
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _collapsedOpacity,
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: widget.startRect.width,
              height: widget.startRect.height,
              child: widget.collapsedTicket,
            ),
          ),
        ),
      ),
    );

    final expandedLayer = Positioned.fill(
      child: FadeTransition(
        opacity: _expandedOpacity,
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: end.width,
            height: end.height,
            child: _ExpandedConcertAfter(
              postItOpacity: _postItOpacity,
              concertTitle: widget.concertTitle,
              ticketInfo: widget.ticketInfo,
              onOutsideTap: _handleOutsideTap,
              onTicketInfoChanged: widget.onTicketInfoChanged,
            ),
          ),
        ),
      ),
    );

    // [백엔드 수정]
    // 이 오버레이는 DiaryPageFrame 바깥의 새 라우트라 안에서 DiaryFrameScale을
    // 못 찾음 - 탭 시점에 넘겨받은 값을 여기서 다시 제공해서, 안의 모든
    // context.sp()가 리스트에서 보이던 것과 같은 배율 사용.
    return Listener(
      onPointerDown: _onPinchPointerDown,
      onPointerMove: _onPinchPointerMove,
      onPointerUp: _onPinchPointerEnd,
      onPointerCancel: _onPinchPointerEnd,
      child: DiaryFrameScale(
        scale: widget.frameScale,
        marginEachSide: 0,
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _close();
          },
          child: Material(
            type: MaterialType.transparency,
            child: AnimatedBuilder(
              animation: _controller,
              child: Stack(children: [collapsedLayer, expandedLayer]),
              builder: (context, child) {
                final t = _t.value;
                final rect = _getRectForT(end, t);
                final radius = _getRadiusForT(t);

                final dimOpacity = lerpDouble(0.0, 0.40, t)!;

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
                        onTapDown: (_) => _handleOutsideTap(),
                        child: const SizedBox.expand(),
                      ),
                    ),

                    // 확장되는 티켓(시작Rect -> 화면 전체) - (1)/(2) 레이어는
                    // child(위에서 한 번만 만든 Stack)를 그대로 재사용.
                    Positioned.fromRect(
                      rect: rect,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        clipBehavior: Clip.antiAlias,
                        child: child,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpandedConcertAfter extends StatelessWidget {
  final Animation<double> postItOpacity;
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final VoidCallback onOutsideTap;
  final ValueChanged<TicketInfo>? onTicketInfoChanged;

  const _ExpandedConcertAfter({
    required this.postItOpacity,
    required this.concertTitle,
    required this.onOutsideTap,
    this.ticketInfo,
    this.onTicketInfoChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 562),
            child: Stack(
              children: [
                // 카드 배경(색/테두리/그림자)만 그리는 장식용 레이어.
                // IgnorePointer로 히트테스트에서 완전히 제외해야, 이 색만
                // 있는 자리(콘텐츠가 비어 있는 곳)를 눌렀을 때 탭이 이
                // 레이어에 막히지 않고 아래 포스터의 "바깥 탭으로 닫기"
                // 감지기까지 그대로 전달됩니다. 그림자가 모서리 클립에
                // 잘리지 않도록 클립 레이어 바깥(이 자리)에 둡니다.
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        // DiaryPageFrame.pageColor 기본값과 동일한
                        // 다이어리 종이색.
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
                    ),
                  ),
                ),

                // 포스터 + 콘텐츠는 카드와 같은 둥근 모서리 밖으로 삐져
                // 나오지 않도록 별도로 clip합니다.
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      // 공연 포스터를 카드 배경 전체에 살짝 투명하게
                      // 겹칩니다. 콘텐츠(2x2 카드)의 인터랙티브 요소가
                      // 그려지는 자리는 이 Stack에서 나중에(=위에) 그려져
                      // 먼저 히트되므로 이 감지기와 경합(arena)하지
                      // 않습니다 — 포스트잇이 아닌 자리(헤더/안내 문구/
                      // 카드 사이 여백)를 눌렀을 때만 이 감지기가 받아서
                      // 오버레이를 닫습니다.
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onOutsideTap,
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
                          onTicketInfoChanged: onTicketInfoChanged,
                        ),
                      ),
                    ],
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
