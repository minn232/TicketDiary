import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/ticket_info.dart';
import '../widgets/concert_before_page_contents.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/responsive_text.dart';

/// 다이어리 화면 위에 "공연 전" 상세를 오버레이로 띄우는 위젯.
///
/// 요구사항 요약
/// - 다이어리 화면 위에 그대로 그려짐(새 페이지로 완전히 전환 X)
/// - 공연 전 티켓을 누르면, 티켓(시작 Rect)이 전체 화면으로 자연스럽게 확장
/// - 확장 후에는 화면을 꽉 채우는 신문지색 카드 한 장 위에 신문 1면
///   ([ConcertBeforePageContents])이 서서히(Fade) 나타남 — 공연 후 페이지와
///   동일한 "단일 카드" 틀입니다(예전의 반투명 포스터 배경/떠 있는 작은 흰
///   카드는 제거).
/// - 닫기: 카드 바깥(어두운 여백) 또는 카드 안 빈 자리를 눌렀을 때만 닫힘
class ConcertBeforeOverlay extends StatefulWidget {
  /// 애니메이션 시작 위치/크기 (다이어리에서 눌린 티켓의 전역 Rect)
  final Rect startRect;

  /// 축소된 상태에서 보여줄 티켓 위젯(다이어리 티켓과 동일한 UI를 넘겨주면 더 자연스럽게 보임)
  final Widget collapsedTicket;

  /// 공연 제목(페이지/포스트잇에 노출)
  final String concertTitle;

  /// 스캔된 티켓 정보(공연장/날짜/가격/좌석 등). 없으면 placeholder가 표시됩니다.
  final TicketInfo? ticketInfo;

  /// 탭한 순간 다이어리 리스트에서 쓰이던 [DiaryFrameScale] 배율.
  //
  // [백엔드 수정]
  // showGeneralDialog는 DiaryPageFrame 바깥의 새 라우트라 안에서
  // DiaryFrameScale을 못 찾고 화면 전체 폭 기준으로 폴백함
  // 탭 시점의 배율을 그대로 넘겨받아 오버레이 안에서도 동일하게 사용.
  final double frameScale;

  /// 이 티켓이 몇 번째로 등록됐는지(신문 "제 N 호"). 다이어리에서 계산해 넘김.
  final int issueNumber;

  const ConcertBeforeOverlay({
    super.key,
    required this.startRect,
    required this.collapsedTicket,
    required this.concertTitle,
    required this.frameScale,
    this.ticketInfo,
    this.issueNumber = 1,
  });

  /// 다이어리 위에 오버레이를 띄우는 헬퍼.
  static Future<void> show(
    BuildContext context, {
    required Rect startRect,
    required Widget collapsedTicket,
    required String concertTitle,
    required double frameScale,
    TicketInfo? ticketInfo,
    int issueNumber = 1,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false, // 반드시 우리 로직(페이지 밖 탭)으로만 닫히도록
      barrierLabel: 'concert_before_overlay',
      barrierColor:
          Colors.transparent, // 다이어리 화면이 비치도록 투명. 실제 dim은 내부에서 애니메이션으로 구현
      pageBuilder: (context, animation, secondaryAnimation) {
        return ConcertBeforeOverlay(
          startRect: startRect,
          collapsedTicket: collapsedTicket,
          concertTitle: concertTitle,
          frameScale: frameScale,
          ticketInfo: ticketInfo,
          issueNumber: issueNumber,
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

  // [백엔드 수정]
  // 축소 티켓 <-> 확장 콘텐츠 크로스페이드 투명도를 매 프레임 double로
  // 계산해서 매 프레임 다시 빌드되던걸 Animation<double>로 미리 만들어두고
  // FadeTransition으로 씌우면 프레임마다 투명도만 갱신.
  late final Animation<double> _expandedOpacity;
  late final Animation<double> _collapsedOpacity;

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

  /// [DiaryPageFrame]은 `SafeArea(child: Center(child: AspectRatio(...)))`로
  /// 프레임을 배치합니다. 여기서도 정확히 같은 기준(SafeArea로 줄어든
  /// 영역, 그 영역의 중앙)을 써야 다이어리 메인 페이지와 같은 규격·위치로
  /// 보입니다(예전엔 SafeArea를 빼먹은 화면 전체 크기를 기준으로 계산해서
  /// 규격이 달랐습니다).
  // [백엔드 수정]
  // t와 무관한 최종(화면 전체로 다 커졌을 때) Rect만 따로 뽑음 - 확장
  // 콘텐츠를 이 고정 크기로 한 번만 레이아웃하고 FittedBox로 지금 박스
  // 크기에 맞춰 통째로 확대/축소하기 위함(아래 _getRectForT 설명 참고).
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
    // 공연 전 페이지 전체 크기를 10% 더 키웁니다(비율은 그대로, 화면
    // 경계를 살짝 넘어가도 규격을 유지하는 걸 우선합니다).
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
    // 시작은 티켓 모서리 둥글게(기존 티켓과 비슷)
    // 끝은 "모달"처럼 보이도록 라운드를 약간 유지
    return lerpDouble(10, 18, t)!;
  }

  /// 카드 바깥(어두운 dim 영역, 포스터 영역) 또는 흰 카드 안이지만
  /// 포스트잇이 아닌 자리(제목/D-day/안내 문구가 있는 여백)를 눌렀을 때
  /// 호출됩니다. 두 곳 모두 "닫기"만 하면 되므로 같은 로직을 공유합니다.
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
            child: _ExpandedConcertBefore(
              postItOpacity: _postItOpacity,
              concertTitle: widget.concertTitle,
              ticketInfo: widget.ticketInfo,
              issueNumber: widget.issueNumber,
              onOutsideTap: _handleOutsideTap,
            ),
          ),
        ),
      ),
    );

    // [백엔드 수정]
    // 이 오버레이는 DiaryPageFrame 바깥의 새 라우트라 안에서 DiaryFrameScale을
    // 못 찾음 - 탭 시점에 넘겨받은 값을 여기서 다시 제공해서, 안의 모든
    // context.sp()가 리스트에서 보이던 것과 같은 배율 사용.
    return DiaryFrameScale(
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

              // 다이어리 화면 dim(불투명하게)
              // - 확장 초반에는 더 약하게, 확장 후반에는 더 강하게
              final dimOpacity = lerpDouble(0.0, 0.40, t)!;

              return Stack(
                children: [
                  // 아래: 다이어리 화면을 어둡게(불투명하게) 만드는 레이어
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        color: Colors.black.withValues(alpha: dimOpacity),
                      ),
                    ),
                  ),

                  // 전체 탭 감지(페이지 바깥을 눌러야만 닫힘). 카드 콘텐츠보다
                  // 먼저(=아래에) 둬야 합니다 — 위에 두면 translucent라도 탭
                  // 제스처 경합(arena)에서 카드 안 인터랙티브 요소와 이
                  // 감지기가 항상 같이 경쟁하게 되어, 곧잘 이 감지기가 이겨서
                  // 카드 안 요소가 눌리지 않는 문제가 있습니다(공연 후
                  // 오버레이에서 실제로 발생). 아래에 두면 카드 안 인터랙티브
                  // 요소가 있는 자리는 그 요소가 먼저 히트되어 이 감지기까지
                  // 도달하지 않고, 카드 바깥(진짜 빈 공간)만 이 감지기가 받습니다.
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
    );
  }
}

class _ExpandedConcertBefore extends StatelessWidget {
  final Animation<double> postItOpacity;
  final String concertTitle;
  final TicketInfo? ticketInfo;
  final int issueNumber;
  final VoidCallback onOutsideTap;

  const _ExpandedConcertBefore({
    required this.postItOpacity,
    required this.concertTitle,
    required this.onOutsideTap,
    required this.issueNumber,
    this.ticketInfo,
  });

  @override
  Widget build(BuildContext context) {
    // 공연 후 페이지([_ExpandedConcertAfter])와 동일한 "단일 카드" 틀:
    // 화면을 꽉 채우는 신문지색 카드 한 장 위에 신문 1면을 얹습니다.
    // 예전의 전체화면 반투명 포스터 배경 + 떠 있는 작은 흰 카드 구조는
    // 제거했습니다.
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 562),
            child: Stack(
              children: [
                // 카드 배경(신문지색/테두리/그림자)만 그리는 장식용 레이어.
                // IgnorePointer로 히트테스트에서 완전히 제외해야, 이 색만
                // 있는 자리(콘텐츠가 비어 있는 곳)를 눌렀을 때 탭이 이
                // 레이어에 막히지 않고 아래 "바깥 탭으로 닫기" 감지기까지
                // 그대로 전달됩니다. 그림자가 모서리 클립에 잘리지 않도록
                // 클립 레이어 바깥(이 자리)에 둡니다.
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        // 신문지(newsprint) 느낌 — 약간 회색끼 도는 미색.
                        color: const Color(0xFFE9E6DC),
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

                // 콘텐츠는 카드와 같은 둥근 모서리 밖으로 삐져나오지 않도록
                // 별도로 clip합니다.
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      // 빈 곳 탭 = 닫기 감지기(투명). 신문 지면의 인터랙티브
                      // 요소는 이 Stack에서 나중에(=위에) 그려져 먼저 히트되므로
                      // 경합하지 않고, 지면이 아닌 빈 자리를 눌렀을 때만 이
                      // 감지기가 받아 오버레이를 닫습니다.
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onOutsideTap,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 22, 20, 18),
                        child: ConcertBeforePageContents(
                          concertTitle: concertTitle,
                          ticketInfo: ticketInfo,
                          postItOpacity: postItOpacity,
                          issueNumber: issueNumber,
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
