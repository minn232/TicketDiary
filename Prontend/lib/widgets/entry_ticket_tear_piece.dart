import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// "공연 후" 티켓의 오른쪽 "입장 티켓" 조각에 쓰는 상호작용.
///
/// - 뜯기 전에는 [front](다른 티켓 오른쪽 칸과 같은 평범한 디자인)가 보이며,
///   "뜯을 수 있다"는 걸 알려주기 위해 누르지 않는 동안은 항상 자동으로 부들부들
///   떨리는(진동) 효과가 반복됩니다. 누르고 있는 동안에는 진동이 멈추고,
///   손을 떼면 다시 진동합니다.
/// - 누른 채로 오른쪽/아래쪽으로 끌면, [front]가 왼쪽 아래 모서리를 고정한 채
///   시계방향으로 최대 [_maxTiltRadians](20도)까지 돌아갑니다.
/// - 20도에 도달하는 순간 찢어지며, 그때부터는 손의 움직임을 그대로 따라
///   이동합니다(손에 종속). 손을 떼면 그 자리에서 서서히 사라지며 [onTorn]이
///   호출됩니다. 20도에 도달하기 전에 손을 떼면 원래 각도(0도)로 돌아갑니다.
/// - 뜯긴 뒤에는 [revealed](예: 지금의 "공연전" 디자인)가 그 자리에 남고,
///   눌렀을 때 [onRevealedTap]이 호출됩니다.
/// - [vibrate]가 false인 동안은 자동 떨림이 멈춰있다가, true로 바뀌는 순간부터
///   떨리기 시작합니다(예: 다른 애니메이션이 끝난 뒤에야 이 힌트를 보여주고
///   싶을 때 씁니다).
/// - [initiallyRevealed]가 true면 처음부터 이미 뜯긴 것으로 보고, [front]
///   없이 바로 [revealed]를 보여줍니다(예: 이전에 뜯어둔 티켓을 다시 열었을 때).
class EntryTicketTearPiece extends StatefulWidget {
  /// 뜯기기 전 보이는 조각(입장 티켓 디자인).
  final Widget front;

  /// 뜯긴 뒤 남는 디자인.
  final Widget revealed;

  /// [revealed]가 보이는 상태에서 눌렀을 때 호출됩니다.
  final VoidCallback? onRevealedTap;

  /// 뜯김이 완료된 순간 호출됩니다.
  final VoidCallback? onTorn;

  final bool enabled;

  /// false인 동안은 자동 떨림을 재생하지 않습니다.
  final bool vibrate;

  /// true면 애니메이션 없이 처음부터 뜯긴 상태(=[revealed])로 시작합니다.
  final bool initiallyRevealed;

  const EntryTicketTearPiece({
    super.key,
    required this.front,
    required this.revealed,
    this.onRevealedTap,
    this.onTorn,
    this.enabled = true,
    this.vibrate = true,
    this.initiallyRevealed = false,
  });

  @override
  State<EntryTicketTearPiece> createState() => _EntryTicketTearPieceState();
}

class _EntryTicketTearPieceState extends State<EntryTicketTearPiece>
    with TickerProviderStateMixin {
  /// 뜯기 전, 누르지 않고 있는 동안 반복 재생되는 "떨림" 애니메이션.
  late final AnimationController _trembleController;

  /// 오른쪽으로 끄는 만큼 0(회전 없음)~1(20도 회전)로 움직이는 기울기 진행도.
  /// 드래그 중에는 직접 값을 설정하고, 손을 뗀 뒤에는 이 컨트롤러로 애니메이션합니다.
  late final AnimationController _tiltController;

  /// 손을 떼서 그 자리에서 서서히 사라지는 1회성 애니메이션.
  late final AnimationController _fadeController;

  /// 오른쪽으로 끌어야 20도까지 회전하는 데 필요한 거리(px).
  static const double _tiltDragDistance = 70.0;

  /// 왼쪽 아래를 고정한 채 돌아가는 최대 각도(20도, 라디안).
  static const double _maxTiltRadians = 20 * math.pi / 180;

  /// 20도에 도달해서 찢어진 뒤, 손의 움직임을 그대로 따라가는 상태.
  bool _detached = false;

  /// 손을 떼서 사라지기 시작한 상태.
  bool _released = false;

  /// 누른 순간부터 계속 누적되는 손(포인터)의 이동량.
  /// 뜯기기 전에는 렌더링에 쓰이지 않지만, 뜯기는 순간 손의 실제 위치와
  /// 어긋나지 않도록 처음부터 계속 추적해둡니다.
  Offset _pointerOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    // 1.5초 진동 + 0.5초 정지가 반복되는 2초 주기.
    _trembleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _tiltController = AnimationController(vsync: this, duration: Duration.zero);
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    if (widget.initiallyRevealed) {
      // 이미 뜯긴 채로 시작: 애니메이션 없이 바로 revealed 상태로 둡니다.
      _detached = true;
      _released = true;
      _fadeController.value = 1.0;
      return;
    }

    // 누르지 않아도 "뜯을 수 있다"는 걸 계속 알려주도록 자동으로 반복 재생.
    // (단, vibrate가 false로 시작하면 아직은 떨지 않습니다.)
    if (widget.vibrate) _trembleController.repeat();
  }

  @override
  void didUpdateWidget(covariant EntryTicketTearPiece oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.vibrate == oldWidget.vibrate) return;
    if (_detached || _released) return; // 이미 뜯긴 뒤라면 떨림과 무관합니다.

    if (widget.vibrate) {
      // 눌려있는 동안(_onPanDown에서 멈춘 경우)이 아니라면 다시 떨기 시작합니다.
      if (!_trembleController.isAnimating) _trembleController.repeat();
    } else {
      _trembleController.stop();
    }
  }

  @override
  void dispose() {
    _trembleController.dispose();
    _tiltController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  void _onPanDown(DragDownDetails details) {
    if (!widget.enabled || _released) return;
    // 누르고 있는 동안에는 진동을 멈춥니다.
    _trembleController.stop();
    // 스냅백 애니메이션이 진행 중이었다면 멈추고, 지금부터는 드래그가 직접 제어합니다.
    _tiltController.stop();
    _pointerOffset = Offset.zero;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!widget.enabled || _released) return;

    // 뜯기기 전/후 상관없이 손의 누적 이동량은 항상 추적합니다. 이렇게 하면
    // 뜯기는 순간 조각의 위치가 어긋나지 않고 바로 손의 현재 위치로 맞춰집니다.
    _pointerOffset += details.delta;

    if (_detached) {
      // 이미 찢어진 뒤: 손의 움직임을 그대로 따라갑니다.
      setState(() {});
      return;
    }

    // 오른쪽(+dx)뿐 아니라 아래쪽(+dy)으로 끄는 것도 찢는 진행도에 더합니다.
    final tearDelta = details.delta.dx + details.delta.dy;
    final next = (_tiltController.value + tearDelta / _tiltDragDistance).clamp(
      0.0,
      1.0,
    );
    _tiltController.value = next;

    if (next >= 1.0) {
      // 20도에 도달하는 순간 찢어지며, 이때부터 손에 종속됩니다.
      // _pointerOffset은 이미 지금까지의 손 이동량을 담고 있으므로 그대로 이어받습니다.
      setState(() => _detached = true);
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (_released) return;
    if (_detached) {
      _beginFadeAway();
    } else {
      _snapTiltBack();
    }
  }

  void _onPanCancel() {
    if (_released) return;
    if (_detached) {
      _beginFadeAway();
    } else {
      _snapTiltBack();
    }
  }

  /// 20도에 도달하지 않은 채로 손을 뗐을 때, 원래 각도(0도)로 되돌립니다.
  void _snapTiltBack() {
    _tiltController
        .animateTo(
          0.0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          if (!mounted || _detached || _released) return;
          if (widget.vibrate) _trembleController.repeat();
        });
  }

  /// 손을 떼서, 그 자리(마지막 위치/각도)에서 서서히 사라집니다.
  void _beginFadeAway() {
    if (_released) return;
    setState(() => _released = true);
    _fadeController.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      widget.onTorn?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final stack = Stack(
      children: [
        // 뜯긴 뒤 남는 디자인. 뜯기기 전에는 입력을 흡수하지 않도록(=비활성) 해둡니다.
        Positioned.fill(
          child: AbsorbPointer(
            absorbing: !_detached,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.enabled ? widget.onRevealedTap : null,
              child: widget.revealed,
            ),
          ),
        ),

        // 뜯기기 전/후 조각. 손을 뗀 뒤(사라지는 동안)에만 입력을 흘려보냅니다.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: _released,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: widget.enabled ? _onPanDown : null,
              onPanUpdate: widget.enabled ? _onPanUpdate : null,
              onPanEnd: widget.enabled ? _onPanEnd : null,
              onPanCancel: widget.enabled ? _onPanCancel : null,
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _trembleController,
                  _tiltController,
                  _fadeController,
                ]),
                builder: (context, child) {
                  if (_released) {
                    final t = Curves.easeInOut.transform(_fadeController.value);
                    // 손을 뗀 그 자리(마지막 위치/각도) 그대로 투명도만 낮춥니다.
                    return Opacity(
                      opacity: (1.0 - t).clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: _pointerOffset,
                        child: Transform.rotate(
                          angle: _maxTiltRadians,
                          alignment: Alignment.bottomLeft,
                          child: child,
                        ),
                      ),
                    );
                  }

                  if (_detached) {
                    // 찢어진 뒤: 손의 움직임을 그대로 따라감(20도로 고정된 채 이동).
                    return Transform.translate(
                      offset: _pointerOffset,
                      child: Transform.rotate(
                        angle: _maxTiltRadians,
                        alignment: Alignment.bottomLeft,
                        child: child,
                      ),
                    );
                  }

                  // 뜯기 전 내내: 뜯을 수 있다는 걸 알려주는 자동 떨림(누르는 동안은 정지).
                  // 2초 주기 중 1.5초는 진동, 0.5초는 정지합니다.
                  const amplitude = 1.2;
                  const vibrateOmegaX = 36.24;
                  const vibrateOmegaY = 30.20;
                  const period = 2.0;
                  const vibrateSeconds = 1.5;

                  final elapsedSeconds = _trembleController.value * period;
                  final isVibrating = elapsedSeconds < vibrateSeconds;

                  final shakeX = isVibrating
                      ? math.sin(elapsedSeconds * vibrateOmegaX) * amplitude
                      : 0.0;
                  final shakeY = isVibrating
                      ? math.cos(elapsedSeconds * vibrateOmegaY) *
                            (amplitude * 0.6)
                      : 0.0;

                  final tiltAngle = _tiltController.value * _maxTiltRadians;

                  return Transform.translate(
                    offset: Offset(shakeX, shakeY),
                    child: Transform.rotate(
                      angle: tiltAngle,
                      alignment: Alignment.bottomLeft,
                      child: child,
                    ),
                  );
                },
                child: widget.front,
              ),
            ),
          ),
        ),
      ],
    );

    if (!widget.enabled) return stack;

    // 데스크톱/웹에서는 마우스 커서를 손가락 모양으로 바꿔, 다른 상호작용 요소들과
    // 동일하게 "누를 수 있는 영역"임을 알려줍니다.
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      return MouseRegion(cursor: SystemMouseCursors.click, child: stack);
    }

    return stack;
  }
}
