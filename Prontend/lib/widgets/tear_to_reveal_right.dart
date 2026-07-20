import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 공연 후 티켓에서 '점선(절취선) 부분을 슬라이드'하면 오른쪽 조각이 뜯기듯 사라지고,
/// 그 자리에 다른 위젯(예: 공연전 칸)이 남는 인터랙션 위젯.
///
/// 동작 요약
/// - 기본 상태: [leftChild] + (점선 절취선) + [rightTearable](뜯는 조각)
/// - 사용자가 절취선([perforationWidth] 영역)을 위→아래 / 아래→위로 슬라이드하면,
///   [rightTearable]이 '오른쪽(+위/아래)로 이동 + 페이드 아웃' 되며 뜯기는 느낌을 만듭니다.
/// - 일정 임계치([tearThreshold]) 이상 드래그하면 완전히 뜯김 상태로 고정되고,
///   [rightRevealed](예: 공연전 칸)이 남습니다.
class TearToRevealRight extends StatefulWidget {
  final bool enabled;

  /// 처음부터 '뜯긴 상태'로 시작할지 여부(앱 재실행 후 상태 복원용)
  final bool initiallyTorn;

  /// 뜯김이 확정(완료)되는 순간 호출되는 콜백(영구 저장용)
  final VoidCallback? onTorn;

  /// 좌측(기념으로 남는) 본표 영역
  final Widget leftChild;

  /// 우측(입장 시 뜯어가는) 조각
  final Widget rightTearable;

  /// 뜯긴 이후 우측에 남을 위젯
  final Widget rightRevealed;

  /// 좌/우 영역 비율
  final int leftFlex;
  final int rightFlex;

  /// 절취선(점선) 영역 폭
  final double perforationWidth;

  /// 드래그 진행률이 이 값을 넘으면 뜯김 상태로 확정
  /// (0.0~1.0)
  final double tearThreshold;

  /// 뜯는 조각이 오른쪽으로 이동하는 거리 배수
  /// - 1.0: 우측 조각 폭만큼 이동
  /// - 1.2: 조금 더 멀리 이동(더 시원한 느낌)
  final double tearSlideDistanceFactor;

  /// 뜯는 방향(위→아래 / 아래→위)에 따라 조각이 위/아래로도 살짝 이동하도록 하는 비율.
  /// - 0.0: 수직 이동 없음
  /// - 0.25: 높이의 25% 만큼 이동
  final double tearVerticalSlideFactor;

  /// 절취선을 '위→아래' 또는 '아래→위'로 긁는(슬라이드) 제스처의 필요 거리(높이 기준 비율).
  ///
  /// 예) 0.65 이면, 절취선 영역에서 세로로 화면 높이의 65%만큼 긁어야 진행률 1.0이 됩니다.
  /// 값이 작을수록 더 쉽게 뜯깁니다.
  final double tearSwipeDistanceFactor;

  /// 뜯김이 취소되어(임계치 미만) 제자리로 되돌아갈 때의 애니메이션 속도.
  final Duration settleDuration;

  /// 뜯김이 확정되었을 때의 애니메이션 속도(되돌아갈 때보다 더 빠르고 경쾌하게).
  final Duration tearConfirmDuration;

  final BorderRadius borderRadius;
  final Color borderColor;

  const TearToRevealRight({
    super.key,
    required this.enabled,
    this.initiallyTorn = false,
    this.onTorn,
    required this.leftChild,
    required this.rightTearable,
    required this.rightRevealed,
    required this.leftFlex,
    required this.rightFlex,
    required this.borderRadius,
    required this.borderColor,
    this.perforationWidth = 8,
    this.tearThreshold = 0.35,
    this.tearSlideDistanceFactor = 1.2,
    this.tearVerticalSlideFactor = 0.22,
    this.tearSwipeDistanceFactor = 0.65,
    this.settleDuration = const Duration(milliseconds: 420),
    this.tearConfirmDuration = const Duration(milliseconds: 240),
  });

  @override
  State<TearToRevealRight> createState() => _TearToRevealRightState();
}

class _TearToRevealRightState extends State<TearToRevealRight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Animation<double>? _anim;

  /// 0.0(붙어있음) -> 1.0(완전히 뜯김)
  double _progress = 0.0;

  /// 제스처 시작 이후 실제로 누적된 세로 이동량(부호 있음, px).
  /// 방향이 왔다갔다해도 순간적으로 뒤집히지 않고 연속적으로 변하므로,
  /// 이 값을 기준으로 조각의 위/아래 흔들림을 그리면 자연스럽게 이어집니다.
  double _netVerticalDrag = 0.0;

  bool _torn = false;

  bool _tornNotified = false;

  @override
  void initState() {
    super.initState();

    _torn = widget.initiallyTorn;
    _progress = _torn ? 1.0 : 0.0;
    _tornNotified = _torn;

    _controller = AnimationController(
      vsync: this,
      duration: widget.settleDuration,
    );
    _controller.addListener(() {
      final a = _anim;
      if (a == null) return;
      if (!mounted) return;
      setState(() => _progress = a.value);
    });
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && _progress >= 0.999) {
        if (!mounted) return;
        if (!_torn) {
          setState(() => _torn = true);
          HapticFeedback.mediumImpact();
        }

        if (!_tornNotified) {
          _tornNotified = true;
          widget.onTorn?.call();
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant TearToRevealRight oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 애니메이션 속도(확정/취소)는 _animateTo 호출 시점마다 직접 지정하므로
    // 여기서 컨트롤러 duration을 미리 맞춰둘 필요는 없습니다.

    // 외부에서 '처음부터 뜯김' 상태가 뒤늦게 로드될 수 있으므로(SharedPreferences),
    // initiallyTorn 변경을 내부 상태에 동기화합니다.
    if (oldWidget.initiallyTorn != widget.initiallyTorn) {
      if (widget.initiallyTorn) {
        if (mounted) {
          setState(() {
            _torn = true;
            _progress = 1.0;
          });
        } else {
          _torn = true;
          _progress = 1.0;
        }
        _tornNotified = true;
      } else {
        // 필요 시 리셋 가능한 구조로 유지(현재 UX에서는 사용하지 않지만 안전하게 처리)
        if (mounted) {
          setState(() {
            _torn = false;
            _progress = 0.0;
          });
        } else {
          _torn = false;
          _progress = 0.0;
        }
        _tornNotified = false;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _animateTo(
    double target, {
    required Duration duration,
    required Curve curve,
  }) {
    if (!mounted) return;
    _controller.stop();
    _controller.reset();
    _controller.duration = duration;
    _anim = Tween<double>(
      begin: _progress,
      end: target,
    ).animate(CurvedAnimation(parent: _controller, curve: curve));
    _controller.forward();
  }

  /// 뜯김이 확정될 때: 빠르고 경쾌하게(살짝 튕기듯) 끝까지 진행.
  void _animateConfirmTear() {
    _animateTo(
      1.0,
      duration: widget.tearConfirmDuration,
      curve: Curves.easeOutCubic,
    );
  }

  /// 뜯김이 취소될 때: 종이가 제자리에 붙듯, 살짝 되튕기며 복귀.
  void _animateSettleBack() {
    _animateTo(0.0, duration: widget.settleDuration, curve: Curves.easeOutBack);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final totalFlex = widget.leftFlex + widget.rightFlex;

        // 요구사항: 점선은 '왼쪽/오른쪽 경계'에 정확히 위치해야 하므로,
        // 레이아웃에 별도 "점선 컬럼"을 두지 않고 경계선 위에 오버레이로 그립니다.
        final leftW = (w * widget.leftFlex / totalFlex).clamp(0.0, w);
        final rightW = (w - leftW).clamp(0.0, w);

        final perfW = widget.perforationWidth;
        final perfLeft = (leftW - perfW / 2).clamp(0.0, w - perfW);

        // 조각이 밀려나가는 실제 이동 거리
        final slideDistance = (rightW * widget.tearSlideDistanceFactor).clamp(
          1.0,
          double.infinity,
        );

        final verticalSlide = (h * widget.tearVerticalSlideFactor).clamp(
          0.0,
          double.infinity,
        );

        // 실제 사용자가 긁은 세로 방향(부호 있음, -1.0~1.0)을 연속적으로 반영합니다.
        // (직전 델타의 부호만 보고 뒤집던 방식은 방향이 바뀔 때 순간적으로 튀어 보였습니다.)
        final verticalDragRange = (h * widget.tearSwipeDistanceFactor).clamp(
          1.0,
          double.infinity,
        );
        final netDragFactor = (_netVerticalDrag / verticalDragRange).clamp(
          -1.0,
          1.0,
        );

        // 진행률 자체를 그대로 쓰지 않고 완만한 가속 곡선을 입혀서,
        // 처음엔 잘 안 뜯기다가(저항) 어느 정도 지나면 훅 뜯기는 느낌을 줍니다.
        final rawProgress = _progress.clamp(0.0, 1.0);
        final visualProgress = Curves.easeIn.transform(rawProgress);

        // 조각은 뜯기는 중반부터 서서히 사라지도록(초반엔 또렷하게 밀려나기만 함).
        const fadeStart = 0.35;
        final fadeT = ((visualProgress - fadeStart) / (1 - fadeStart)).clamp(
          0.0,
          1.0,
        );
        final pieceOpacity = 1.0 - fadeT;

        // 종이가 뜯기며 살짝 비틀리는 느낌을 주는 미세한 회전.
        const maxTiltRadians = 0.12;
        final tiltAngle = visualProgress * netDragFactor * maxTiltRadians;

        Widget perforation() {
          return SizedBox(
            width: perfW,
            height: h,
            child: CustomPaint(
              // 요구사항: 절취선은 항상 점선만 사용(실선 제거)
              painter: _PerforationPainter(
                color: Colors.black.withValues(alpha: 0.25),
                dashHeight: 6,
                dashGap: 6,
                thickness: 1.4,
              ),
            ),
          );
        }

        // 우측 조각이 뜯길 때(Transform.translate) 카드 영역 밖으로도 그려질 수 있어야 하므로,
        // 전체를 ClipRRect로 감싸지 않고,
        // 1) 바닥(티켓 본체)만 라운드+클립
        // 2) 뜯기는 조각은 별도 레이어(clip none)에서 이동
        // 으로 구성합니다.
        final rightPieceRadius = BorderRadius.only(
          topRight: widget.borderRadius.topRight,
          bottomRight: widget.borderRadius.bottomRight,
        );

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // 바닥 레이어: 티켓 본체(좌측 본표 + 우측 revealed)
            SizedBox(
              width: w,
              height: h,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: widget.borderRadius,
                  border: Border.all(color: widget.borderColor, width: 1),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: widget.leftFlex, child: widget.leftChild),
                    Expanded(
                      flex: widget.rightFlex,
                      child: AbsorbPointer(
                        absorbing: !_torn,
                        child: widget.rightRevealed,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 뜯기 전: 우측 조각이 바닥 레이어 위에 덮여 있음
            // - 이 레이어는 Clip 되지 않으므로, 뜯기 애니메이션이 다른 위젯 위로도 넘어갈 수 있습니다.
            if (!_torn)
              Positioned(
                left: leftW,
                top: 0,
                width: rightW,
                height: h,
                child: IgnorePointer(
                  // 드래그는 점선에서만 받기 때문에, 조각 자체는 포인터를 막지 않음
                  ignoring: true,
                  child: Opacity(
                    opacity: pieceOpacity,
                    child: Transform.translate(
                      offset: Offset(
                        visualProgress * slideDistance,
                        visualProgress * verticalSlide * netDragFactor,
                      ),
                      child: Transform.rotate(
                        angle: tiltAngle,
                        child: ClipRRect(
                          // 이동 중에도 우측 모서리 라운드가 유지되도록
                          borderRadius: rightPieceRadius,
                          clipBehavior: Clip.antiAlias,
                          child: SizedBox.expand(child: widget.rightTearable),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // 점선(절취선): left/right 경계선에 정확히 위치
            // - 뜯기는 조각 위에 항상 보이도록(레이어 최상단에) 배치
            Positioned(
              left: perfLeft,
              top: 0,
              bottom: 0,
              width: perfW,
              child: perforation(),
            ),

            // 드래그 입력은 '점선(절취선) 영역'에서만 받음
            if (!_torn)
              Positioned(
                left: perfLeft,
                top: 0,
                bottom: 0,
                width: perfW,
                child: AbsorbPointer(
                  absorbing: !widget.enabled,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: (_) {
                      // 진행 중인 settle 애니메이션이 있으면 멈추고, 사용자의 드래그를 우선
                      _controller.stop();
                      _netVerticalDrag = 0.0;
                    },
                    // 요구사항: 점선(절취선) 영역을 '위→아래 / 아래→위'로 슬라이드하면 뜯김 진행
                    onVerticalDragUpdate: (details) {
                      final swipeDistance = (h * widget.tearSwipeDistanceFactor)
                          .clamp(1.0, double.infinity);

                      // 방향이 바뀌어도 순간적으로 뒤집히지 않도록, 실제 누적 이동량을 그대로 더합니다.
                      _netVerticalDrag += details.delta.dy;

                      // 위/아래 어느 방향이든 긁은 정도(절대값)만큼 뜯김 진행률에 더합니다.
                      final prev = _progress;
                      final next =
                          (_progress + (details.delta.dy.abs() / swipeDistance))
                              .clamp(0.0, 1.0);

                      if (!mounted) return;
                      if (next != _progress) {
                        setState(() => _progress = next);
                      }

                      // 충분히 긁으면 손을 떼기 전이라도 뜯김 확정 애니메이션으로 전환
                      // (이미 1.0에 도달한 상태에서 반복적으로 reset/forward 되며 튀는 현상 방지)
                      if (prev < 1.0 && next >= 1.0) {
                        _animateConfirmTear();
                      }
                    },
                    onVerticalDragEnd: (details) {
                      if (_progress >= widget.tearThreshold) {
                        _animateConfirmTear();
                      } else {
                        _animateSettleBack();
                      }
                    },
                    onVerticalDragCancel: _animateSettleBack,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 점선(절취선) 페인터
class _PerforationPainter extends CustomPainter {
  final Color color;
  final double dashHeight;
  final double dashGap;
  final double thickness;

  const _PerforationPainter({
    required this.color,
    this.dashHeight = 6,
    this.dashGap = 6,
    this.thickness = 1.4,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;

    final x = size.width / 2;
    double y = 8;
    while (y < size.height - 8) {
      final y2 = (y + dashHeight).clamp(0.0, size.height);
      canvas.drawLine(Offset(x, y), Offset(x, y2), paint);
      y += dashHeight + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant _PerforationPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.dashHeight != dashHeight ||
        oldDelegate.dashGap != dashGap ||
        oldDelegate.thickness != thickness;
  }
}
