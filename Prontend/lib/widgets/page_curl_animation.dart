import 'package:flutter/material.dart';

/// 이벤트 기반 Page Curl 애니메이션
///
/// 사용 예시:
/// ```dart
/// final controller = PageCurlAnimationController();
///
/// PageCurlAnimation(
///   controller: controller,
///   child: YourWidget(),
/// )
///
/// // 이벤트 발생 시
/// controller.play(); // 재생
/// controller.playReverse(); // 역재생
/// ```
class PageCurlAnimation extends StatefulWidget {
  final Widget child;
  final PageCurlAnimationController controller;
  final Duration duration;
  final VoidCallback? onComplete;

  const PageCurlAnimation({
    required this.child,
    required this.controller,
    this.duration = const Duration(milliseconds: 800),
    this.onComplete,
    super.key,
  });

  @override
  State<PageCurlAnimation> createState() => _PageCurlAnimationState();
}

class _PageCurlAnimationState extends State<PageCurlAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    // 컨트롤러에 애니메이션 컨트롤러 연결
    widget.controller._setAnimationController(_animationController);
    widget.controller._onComplete = widget.onComplete;
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        final progress = _animationController.value;

        // progress: 0.0 (시작) → 1.0 (완료)
        // 오른쪽 아래에서 시작해서 왼쪽으로 넘어가는 효과
        final rotationAngle = progress * 0.5; // 0도 → 약 28도
        final offsetX = progress * 120.0; // 오른쪽에서 왼쪽으로
        final offsetY = (1.0 - (progress - 0.5).abs() * 2).clamp(0.0, 1.0) * 60.0;
        final opacity = 0.7 + 0.3 * (1.0 - (progress - 0.5).abs() * 2).clamp(0.0, 1.0);

        // 3D 변환 매트릭스 구성
        final matrix = Matrix4.identity()
          ..setEntry(3, 2, 0.003) // 원근감
          ..setEntry(0, 3, -offsetX) // x축 평행이동
          ..setEntry(1, 3, -offsetY) // y축 평행이동
          ..rotateY(-rotationAngle); // Y축 회전

        return Transform(
          alignment: Alignment.bottomRight,
          transform: matrix,
          child: Opacity(
            opacity: opacity,
            child: Material(
              color: Colors.transparent,
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Page Curl 애니메이션 컨트롤러
///
/// 애니메이션 재생, 일시정지, 역재생을 제어합니다.
class PageCurlAnimationController extends ChangeNotifier {
  late AnimationController _animationController;
  VoidCallback? _onComplete;

  void _setAnimationController(AnimationController controller) {
    _animationController = controller;
  }

  void _onAnimationComplete() {
    _onComplete?.call();
  }

  /// 애니메이션 재생 (0.0 → 1.0)
  /// 완료 후 자동으로 역재생
  Future<void> play() async {
    await _animationController.forward();
    await Future.delayed(const Duration(milliseconds: 100));
    await playReverse();
  }

  /// 즉시 완료 상태로 이동 후 역재생
  Future<void> playReverse() async {
    _animationController.reset();
    await _animationController.forward();
    _onAnimationComplete();
  }

  /// 일시정지
  void pause() {
    _animationController.stop();
  }

  /// 초기 상태로 리셋
  void reset() {
    _animationController.reset();
  }

  /// 현재 애니메이션 값 (0.0 ~ 1.0)
  double get value => _animationController.value;

  /// 애니메이션 상태
  AnimationStatus get status => _animationController.status;

  /// 애니메이션 실행 중인지 여부
  bool get isAnimating => _animationController.isAnimating;

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }
}






