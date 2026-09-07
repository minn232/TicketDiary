import 'package:flutter/material.dart';

import 'app_network_image.dart';
import 'poster_background.dart';

/// 포스터를 전체화면으로 확대해서 보여줍니다(소식 탭 상세의 포스터 확대와
/// 동일한 동작): 어두운 배경 + 핀치 줌([InteractiveViewer]) + 더블탭으로
/// 확대/축소 + 포스터 바깥(또는 확대 안 된 상태의 포스터 여백)을 누르면 닫힘.
///
/// 어디서든 재사용할 수 있도록 라우트로 띄웁니다(공연 전 신문 지면의 포스터
/// 더블탭, 소식 상세 등에서 공용).
Future<void> showFullscreenPoster(BuildContext context, String? imageUrl) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => _FullscreenPosterView(imageUrl: imageUrl),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _FullscreenPosterView extends StatefulWidget {
  final String? imageUrl;

  const _FullscreenPosterView({required this.imageUrl});

  @override
  State<_FullscreenPosterView> createState() => _FullscreenPosterViewState();
}

class _FullscreenPosterViewState extends State<_FullscreenPosterView> {
  final TransformationController _zoomController = TransformationController();
  TapDownDetails? _doubleTapDetails;
  static const double _doubleTapZoomScale = 2.5;

  @override
  void dispose() {
    _zoomController.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  void _handleDoubleTapDown(TapDownDetails details) =>
      _doubleTapDetails = details;

  void _handleDoubleTap() {
    final isZoomedIn = _zoomController.value.getMaxScaleOnAxis() > 1.01;
    if (isZoomedIn) {
      _zoomController.value = Matrix4.identity();
      return;
    }
    final position = _doubleTapDetails?.localPosition ?? Offset.zero;
    const scale = _doubleTapZoomScale;
    _zoomController.value = Matrix4.identity()
      ..translateByDouble(
        -position.dx * (scale - 1),
        -position.dy * (scale - 1),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        color: Colors.black.withValues(alpha: 0.92),
        child: Stack(
          children: [
            // 바깥(패딩·상태바) 영역 탭 → 닫기.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: InteractiveViewer(
                  transformationController: _zoomController,
                  minScale: 1.0,
                  maxScale: _doubleTapZoomScale * 2,
                  // 닫기 감지기를 InteractiveViewer "안쪽"(포스터 뒤)에 둡니다.
                  // 확대 전 포스터의 실제 영역 밖(여백)을 눌러도 닫히도록.
                  // 포스터 자체는 위에 얹은 GestureDetector가 (불투명하게) 탭을
                  // 흡수해 안 닫히고, 더블탭 확대/축소만 처리합니다.
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _close,
                        ),
                      ),
                      Center(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onDoubleTapDown: _handleDoubleTapDown,
                          onDoubleTap: _handleDoubleTap,
                          child: _LargePoster(imageUrl: widget.imageUrl),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LargePoster extends StatelessWidget {
  final String? imageUrl;

  const _LargePoster({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return const AspectRatio(
        aspectRatio: 3 / 4,
        child: ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          child: PosterGradientPlaceholder(),
        ),
      );
    }
    // [백엔드 수정]
    // Image.network -> AppNetworkImage(디스크 캐싱+디코드 크기 축소).
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AppNetworkImage(
        url,
        fit: BoxFit.contain,
        errorBuilder: (context) => const AspectRatio(
          aspectRatio: 3 / 4,
          child: PosterGradientPlaceholder(),
        ),
      ),
    );
  }
}
