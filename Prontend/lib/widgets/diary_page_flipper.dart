import 'dart:math' as math;
import 'package:flutter/material.dart';

class DiaryPageFlipper extends StatefulWidget {
  final Widget frontPage; // 현재 페이지
  final Widget backPage; // 다음 페이지 뒷면
  final VoidCallback? onFlipForward; // 다음 페이지로 넘어갈 때 콜백
  final bool flipUpward; // true: 위로 넘김, false: 아래로 넘김
  /// 플립 애니메이션 진행 중인지 알려주는 notifier.
  final ValueNotifier<bool>? animatingNotifier;

  const DiaryPageFlipper({
    super.key,
    required this.frontPage,
    required this.backPage,
    this.onFlipForward,
    this.flipUpward = true,
    this.animatingNotifier,
  });

  @override
  State<DiaryPageFlipper> createState() => _DiaryPageFlipperState();
}

class _DiaryPageFlipperState extends State<DiaryPageFlipper>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late AnimationController _slideController;
  bool _isAutoFlipping = false;

  @override
  void initState() {
    super.initState();
    // 애니메이션 진행도 (0.0: 정지 ~ 1.0: 다음 페이지)
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );

    // 슬라이드 애니메이션 (0.0 ~ 1.0)
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );

    _controller.addListener(_syncAnimatingNotifier);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed &&
          widget.animatingNotifier != null) {
        widget.animatingNotifier!.value = false;
        _slideController.value = 0.0;
      }
    });
  }

  void _syncAnimatingNotifier() {
    final notifier = widget.animatingNotifier;
    if (notifier == null) return;
    final isAnimating =
        _controller.isAnimating || _controller.value != 0.0 || _isAutoFlipping;
    if (notifier.value != isAnimating) {
      notifier.value = isAnimating;
    }
  }

  void _handleForwardFlip() {
    if (_isAutoFlipping) return;
    _isAutoFlipping = true;

    Future.wait([_controller.forward(), _slideController.forward()]).then((_) {
      if (mounted) {
        widget.onFlipForward?.call();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) {
        if (_isAutoFlipping) return;
        // 넘어갈 다음 페이지가 없으면(마지막 페이지) 애니메이션을 아예 시작하지 않습니다.
        // 그렇지 않으면 backPage/frontPage가 동시에 빌드되며, 두 페이지가 같은 티켓
        // 목록을 그리게 되어 티켓별 GlobalKey가 중복되어 오류가 발생합니다.
        if (widget.onFlipForward == null) return;

        // 왼쪽으로 스와이프 (음수) -> value 증가 (0.0 -> 1.0)
        double delta =
            (details.primaryDelta ?? 0.0) / MediaQuery.of(context).size.width;
        _controller.value -= delta;
        _slideController.value = _controller.value;

        // 90도(0.5)를 넘어가면 자동으로 페이지를 넘김
        if (_controller.value > 0.5) {
          _handleForwardFlip();
        }
      },
      onHorizontalDragEnd: (details) {
        if (_isAutoFlipping) return;
        if (widget.onFlipForward == null) return;

        final velocity = details.primaryVelocity ?? 0.0;

        // 왼쪽으로 빠르게 스와이프(velocity < 0) 혹은 이미 절반 이상 넘긴 경우
        if (_controller.value > 0.5 || velocity < -300) {
          _handleForwardFlip();
        } else {
          // 제자리 복귀
          _controller.animateTo(0.0);
          _slideController.animateTo(0.0);
        }
      },
      child: SizedBox.expand(
        child: AnimatedBuilder(
          animation: Listenable.merge([_controller, _slideController]),
          builder: (context, child) {
            final angle = _controller.value * math.pi;
            final matrix = Matrix4.identity()..setEntry(3, 2, 0.001);

            if (widget.flipUpward) {
              matrix.rotateX(angle);
            } else {
              matrix.rotateY(angle);
            }

            final slideOffset = _slideController.value * 30.0;

            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 1. 정지 상태
                  if (_controller.value == 0)
                    Positioned.fill(
                      child: RepaintBoundary(child: widget.frontPage),
                    )
                  // 2. 애니메이션 진행 상태
                  else ...[
                    // 바닥 레이어 (다음 페이지)
                    Positioned.fill(
                      child: RepaintBoundary(child: widget.backPage),
                    ),
                    // 회전 레이어 (현재 페이지)
                    // 90도(0.5)를 넘어가면 뒷면이 보이므로 숨깁니다.
                    if (_controller.value <= 0.5)
                      Positioned.fill(
                        child: Transform.translate(
                          offset: Offset(-slideOffset, 0),
                          child: Transform(
                            transform: matrix,
                            alignment: widget.flipUpward
                                ? Alignment.topCenter
                                : Alignment.centerLeft,
                            child: RepaintBoundary(child: widget.frontPage),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _slideController.dispose();
    super.dispose();
  }
}
