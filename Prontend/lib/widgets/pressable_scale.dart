import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 눌렀을 때 살짝 "커졌다가"(팝) "원래 크기"로 돌아오는 클릭 애니메이션.
///
/// 사용 예:
/// ```dart
/// PressableScale(
///   onTap: () {},
///   child: YourWidget(),
/// )
/// ```
///
/// - 누르는 동안: 약간 축소([pressScale])
/// - 손을 떼는 순간: 약간 확대([tapScale]) 후 원래 크기(1.0)로 복귀
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 누르고 있을 때 스케일(1.0 미만 권장)
  final double pressScale;

  /// 탭 순간 팝(확대) 스케일(1.0 초과 권장)
  final double tapScale;

  final Duration pressDuration;
  final Duration popInDuration;
  final Duration popOutDuration;

  /// 스케일 기준점
  final Alignment alignment;

  /// 제스처 히트 테스트
  final HitTestBehavior behavior;

  /// onTap이 null이면 비활성화(애니메이션/커서 변경 없음)
  final bool enabled;

  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressScale = 0.97,
    this.tapScale = 1.04,
    this.pressDuration = const Duration(milliseconds: 80),
    this.popInDuration = const Duration(milliseconds: 90),
    this.popOutDuration = const Duration(milliseconds: 120),
    this.alignment = Alignment.center,
    this.behavior = HitTestBehavior.opaque,
    bool? enabled,
  }) : enabled = enabled ?? (onTap != null || onLongPress != null);

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this, value: 1.0);
  }

  @override
  void didUpdateWidget(covariant PressableScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 비활성화로 바뀌면 원래 크기로 복귀
    if (!widget.enabled && _controller.value != 1.0) {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _animateTo(double value, {required Duration duration, required Curve curve}) async {
    if (!mounted) return;
    try {
      await _controller.animateTo(value, duration: duration, curve: curve);
    } catch (_) {
      // controller가 dispose되거나 다른 애니메이션으로 중단될 수 있음
    }
  }

  void _onTapDown(TapDownDetails _) {
    if (!widget.enabled) return;
    _controller.stop();
    _animateTo(widget.pressScale, duration: widget.pressDuration, curve: Curves.easeOutCubic);
  }

  void _onTapCancel() {
    if (!widget.enabled) return;
    _controller.stop();
    _animateTo(1.0, duration: widget.popOutDuration, curve: Curves.easeOutCubic);
  }

  void _onTapUp(TapUpDetails _) {
    if (!widget.enabled) return;
    _controller.stop();

    // 눌림(축소) -> 팝(확대) -> 원래 크기
    () async {
      await _animateTo(widget.tapScale, duration: widget.popInDuration, curve: Curves.easeOut);
      await _animateTo(1.0, duration: widget.popOutDuration, curve: Curves.easeOutBack);
    }();
  }

  @override
  Widget build(BuildContext context) {
    final interactive = widget.enabled;

    Widget current = AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final scale = _controller.value.clamp(0.85, 1.15);
        return Transform.scale(
          scale: scale,
          alignment: widget.alignment,
          child: child,
        );
      },
    );

    if (!interactive) return current;

    current = GestureDetector(
      behavior: widget.behavior,
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: current,
    );

    if (kIsWeb || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows) {
      current = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: current,
      );
    }

    return current;
  }
}


