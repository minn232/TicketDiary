import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 탭하면 앞/뒷면이 뒤집히는 플립(Flip) 카드 위젯.
///
/// ## 이 파일에서 조절 가능한 포인트
/// - [duration] : 뒤집히는 속도
/// - [curve] : 뒤집히는 가속/감속 느낌
/// - [perspective] : 3D 원근감(값이 클수록 3D 왜곡/움직임이 커짐)
/// - [clipBehavior] / [borderRadius] : 뒤집는 동안 위젯이 원래 영역 밖으로 그려지지 않도록 클리핑
///
/// ## 구현 방식
/// - 외부 패키지 없이 `Matrix4 + rotateY`로 구현
/// - 애니메이션이 90도(0.5) 지점을 넘으면 front/back을 교체
/// - back은 추가로 180도 회전시켜(rotateY(pi)) 글자가 정상 방향으로 보이게 함
class TicketFlipCard extends StatefulWidget {
  /// 앞면 위젯
  final Widget front;

  /// 뒷면 위젯
  final Widget back;

  /// 뒤집는 애니메이션 시간
  final Duration duration;

  /// 뒤집는 애니메이션 커브(감속/가속 느낌)
  final Curve curve;

  /// 비활성화 시 탭 제스처를 등록하지 않아,
  /// 상위 GestureDetector(예: 화면 탭 시 닫기)가 우선 동작할 수 있게 합니다.
  final bool enabled;

  /// true이면 시작부터 뒷면 상태로 표시
  final bool initiallyFlipped;

  /// 3D 원근감(값이 클수록 왜곡/입체감이 커짐).
  ///
  /// - 너무 크면: 카드가 회전할 때 화면 위로 "크게 튀어나오는" 느낌이 강해질 수 있음
  /// - 너무 작으면: 2D처럼 보이지만 움직임은 가장 안정적
  ///
  /// 일반적으로 0.0003~0.0015 사이에서 취향에 맞게 조절하는 것을 권장합니다.
  final double perspective;

  /// 회전 중에도 카드가 원래 영역 밖으로 그려지지 않도록 클리핑합니다.
  ///
  /// - Clip.none : 클리핑 하지 않음(회전 중 바깥으로 그려질 수 있음)
  /// - Clip.hardEdge : 성능 좋��(기본값)
  /// - Clip.antiAlias : 모서리가 더 부드러움(약간 더 비용)
  ///
  /// "뒤집힐 때 다른 공간 위에 그려지는 범위"를 최소화하려면 Clip.none이 아닌 값으로 두세요.
  final Clip clipBehavior;

  /// [clipBehavior]가 Clip.none이 아닐 때 적용할 모서리 라운드.
  ///
  /// 티켓 위젯이 이미 borderRadius를 가지고 있더라도,
  /// 플립 중 오버플로우/겹침 방지를 위해 바깥에서 한 번 더 클리핑하는 것이 유용합니다.
  final BorderRadius? borderRadius;

  const TicketFlipCard({
    super.key,
    required this.front,
    required this.back,
    this.duration = const Duration(milliseconds: 520),
    this.curve = Curves.easeInOutCubic,
    this.enabled = true,
    this.initiallyFlipped = false,
    // 기본 원근감(필요하면 화면별로 override 하세요)
    this.perspective = 0.0005,

    // 기본은 클리핑 켜짐: 회전 중 카드가 원래 영역 밖으로 그려지는 현상을 줄임
    this.clipBehavior = Clip.hardEdge,

    // 라운드가 필요한 경우 외부에서 전달(예: BorderRadius.circular(8))
    this.borderRadius,
  });

  @override
  State<TicketFlipCard> createState() => _TicketFlipCardState();
}

class _TicketFlipCardState extends State<TicketFlipCard> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();

    // _controller.value:
    // - 0.0 => 앞면(front)
    // - 1.0 => 뒷면(back)
    // 중간 값(0.0~1.0)에서 rotateY로 회전 각도를 계산합니다.
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: widget.initiallyFlipped ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(covariant TicketFlipCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 위젯이 rebuild 되며 duration이 변경될 수 있으므로 컨트롤러도 동기화
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!widget.enabled) return;

    // 0.5를 기준으로 앞/뒤 상태를 판정해서 목표값으로 animate
    // - 현재가 앞면( < 0.5 )이면 -> 1.0(뒷면)으로
    // - 현재가 뒷면( >= 0.5 )이면 -> 0.0(앞면)으로
    final target = _controller.value < 0.5 ? 1.0 : 0.0;

    try {
      await _controller.animateTo(target, curve: widget.curve);
    } catch (_) {
      // dispose/interrupt 등으로 애니메이션이 중단될 수 있음
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget current = AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // 진행도(0.0~1.0)
        final t = _controller.value;

        // 90도(0.5) 이전에는 앞면, 이후에는 뒷면을 보여줌
        final showFront = t < 0.5;

        // 회전 각도: 0(0도) -> pi(180도)
        final angle = t * math.pi;

        // 90도를 넘은 뒤에는 뒷면이 정방향으로 보이도록 180도 추가 회전
        // (그냥 back을 보여주면 글씨가 좌우 반전되어 보이기 때문)
        final child = showFront
            ? widget.front
            : Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()..rotateY(math.pi),
                child: widget.back,
              );

        // 실제 3D 변환
        // - setEntry(3, 2, perspective): 원근감 부여
        // - rotateY(angle): 좌우 회전
        // perspective 값을 낮추면 회전 중 "튀어나오는" 느낌이 줄고 안정적으로 보입니다.
        final transform = Matrix4.identity()
          ..setEntry(2, 2, widget.perspective)
          ..rotateY(angle);

        return Transform(
          alignment: Alignment.center,
          transform: transform,
          child: child,
        );
      },
    );

    if (widget.enabled) {
      current = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: current,
      );

      if (kIsWeb ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux) {
        current = MouseRegion(cursor: SystemMouseCursors.click, child: current);
      }
    }

    if (widget.clipBehavior != Clip.none) {
      // 회전(Transform)은 레이아웃 크기를 바꾸지 않지만, 그려지는 영역은 커질 수 있습니다.
      // 따라서 clip을 켜두면 다른 위젯 위로 그려져 "움직임이 커 보이는" 문제를 줄일 수 있습니다.
      if (widget.borderRadius != null) {
        current = ClipRRect(
          borderRadius: widget.borderRadius!,
          clipBehavior: widget.clipBehavior,
          child: current,
        );
      } else {
        current = ClipRect(
          clipBehavior: widget.clipBehavior,
          child: current,
        );
      }
    }

    return current;
  }
}

