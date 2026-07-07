import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pressable_scale.dart';

/// 다이어리 UI의 공통 프레임(가죽 배경 + 겹친 페이지 레이어 + 바인더 링 + 우측 탭)을
/// 여러 화면에서 재사용하기 위한 래퍼 위젯.
class DiaryPageFrame extends StatelessWidget {
  final Widget child;
  final bool isTabRoot;
  final Color backgroundColor;
  final Color pageColor;
  final List<DiaryPageLayerSpec> pageLayers;
  final List<DiarySideTabSpec> sideTabs;
  final double pageTop;
  final double pageBottom;
  final double pageLeft;
  final double pageRight;
  final bool showBinderRings;
  final int binderRingCount;
  final double binderLeft;
  final double binderTop;
  final double binderBottom;
  final double binderRingCircleShiftX;
  final bool useSafeArea;
  final bool animateMainPage;
  final Widget? overlayMainPage;
  final ValueListenable<bool>? overlayMainPageVisibleNotifier;

  const DiaryPageFrame({
    super.key,
    required this.child,
    this.isTabRoot = false,
    this.backgroundColor = const Color(0xFF5C4033),
    this.pageColor = const Color(0xFFF4F1E1),
    this.pageLayers = const [
      DiaryPageLayerSpec(right: 35, bottom: 20),
      DiaryPageLayerSpec(right: 38, bottom: 20),
      DiaryPageLayerSpec(right: 41, bottom: 20),
      DiaryPageLayerSpec(right: 44, bottom: 20),
    ],
    this.sideTabs = const [],
    this.pageTop = 10,
    this.pageBottom = 20,
    this.pageLeft = 30,
    this.pageRight = 45,
    this.showBinderRings = true,
    this.binderRingCount = 6,
    this.binderLeft = -15,
    this.binderTop = 50,
    this.binderBottom = 50,
    this.binderRingCircleShiftX = 8,
    this.useSafeArea = true,
    this.animateMainPage = false,
    this.overlayMainPage,
    this.overlayMainPageVisibleNotifier,
  });

  @override
  Widget build(BuildContext context) {
    const sideTabWidth = DiaryIndexTab.defaultWidth;
    const sideTabHeight = DiaryIndexTab.defaultHeight;

    final activeTabs = sideTabs.where((t) => t.isActive).toList(growable: false);

    final frame = Stack(
      clipBehavior: Clip.none,
      children: [
        /// 1. 뒤쪽 페이지 레이어들
        for (final layer in pageLayers)
          _DiaryPageLayer(
            right: layer.right,
            bottom: layer.bottom,
            pageColor: pageColor,
            pageTop: pageTop,
            pageLeft: pageLeft,
          ),

        /// 2. 기본 우측 탭들 (종이 뒤에 배치)
        for (final tab in sideTabs)
          Positioned(
            right: tab.right,
            top: tab.top,
            child: tab.onTap == null
                ? tab.child
                : PressableScale(
                    onTap: tab.onTap,
                    pressScale: 0.985,
                    tapScale: 1.03,
                    child: tab.child,
                  ),
          ),

        /// 3. 메인 페이지 (정적 컨텐츠)
        Positioned(
          top: pageTop,
          bottom: pageBottom,
          left: pageLeft,
          right: pageRight,
          child: animateMainPage
              ? child
              : Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: pageColor,
                    borderRadius: const BorderRadius.horizontal(right: Radius.circular(15)),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(5, 5)),
                    ],
                  ),
                  child: child,
                ),
        ),

        /// 4. 애니메이션용 메인 페이지 오버레이 (탭보다 위에, 활성 탭 스티커보다 아래에)
        if (overlayMainPage != null)
          Positioned(
            top: pageTop,
            bottom: pageBottom,
            left: pageLeft,
            right: pageRight,
            child: overlayMainPageVisibleNotifier == null
                ? overlayMainPage!
                : ValueListenableBuilder<bool>(
                    valueListenable: overlayMainPageVisibleNotifier!,
                    builder: (context, visible, _) {
                      return visible ? overlayMainPage! : const SizedBox.shrink();
                    },
                  ),
          ),

        /// 5. 활성 탭 스티커 레이어 (메인 페이지 종이 위로 드러나는 부분)
        for (final tab in activeTabs)
          Positioned(
            right: tab.right,
            top: tab.top,
            child: SizedBox(
              width: sideTabWidth,
              height: sideTabHeight,
              child: ClipRect(
                child: Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: (() {
                    final outside = (pageRight - tab.right).clamp(0.0, sideTabWidth);
                    final inside = (sideTabWidth - outside).clamp(0.0, sideTabWidth);
                    return (inside / sideTabWidth).clamp(0.0, 1.0);
                  })(),
                  child: tab.onTap == null
                      ? tab.child
                      : PressableScale(
                          onTap: tab.onTap,
                          pressScale: 0.985,
                          tapScale: 1.03,
                          child: tab.child,
                        ),
                ),
              ),
            ),
          ),

        /// 6. 왼쪽 바인더 링 (최상단)
        if (showBinderRings)
          Positioned(
            left: binderLeft,
            top: binderTop,
            bottom: binderBottom,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(
                binderRingCount,
                (index) => _BinderRing(circleShiftX: binderRingCircleShiftX),
              ),
            ),
          ),
      ],
    );

    final scaffold = Scaffold(
      backgroundColor: backgroundColor,
      body: useSafeArea ? SafeArea(child: frame) : frame,
    );

    if (!isTabRoot) return scaffold;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final platform = Theme.of(context).platform;
        if (platform == TargetPlatform.android) {
          SystemNavigator.pop();
        }
      },
      child: scaffold,
    );
  }
}

class DiaryPageLayerSpec {
  final double right;
  final double bottom;
  const DiaryPageLayerSpec({required this.right, required this.bottom});
}

class DiarySideTabSpec {
  final double right;
  final double top;
  final Widget child;
  final VoidCallback? onTap;
  final bool isActive;
  const DiarySideTabSpec({
    required this.right,
    required this.top,
    required this.child,
    this.onTap,
    this.isActive = false,
  });
}

class DiaryIndexTab extends StatelessWidget {
  static const double defaultWidth = 45;
  static const double defaultHeight = 90;
  final Color color;
  final String text;
  final bool rotateText;
  final double width;
  final double height;
  final BorderRadius borderRadius;
  final TextStyle textStyle;

  const DiaryIndexTab({
    super.key,
    required this.color,
    required this.text,
    this.rotateText = true,
    this.width = defaultWidth,
    this.height = defaultHeight,
    this.borderRadius = const BorderRadius.horizontal(left: Radius.circular(10), right: Radius.circular(5)),
    this.textStyle = const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87),
  });

  @override
  Widget build(BuildContext context) {
    final label = Text(text, style: textStyle);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 4, offset: const Offset(-2, 2)),
          BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 3, offset: const Offset(2, 2)),
        ],
      ),
      child: Center(
        child: rotateText ? RotatedBox(quarterTurns: 1, child: label) : label,
      ),
    );
  }
}

class _DiaryPageLayer extends StatelessWidget {
  final double right;
  final double bottom;
  final double pageTop;
  final double pageLeft;
  final Color pageColor;
  const _DiaryPageLayer({
    required this.right,
    required this.bottom,
    required this.pageTop,
    required this.pageLeft,
    required this.pageColor,
  });
  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: pageTop,
      bottom: bottom,
      left: pageLeft,
      right: right,
      child: Container(
        decoration: BoxDecoration(
          color: pageColor,
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(15)),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8, offset: const Offset(4, 4)),
          ],
        ),
      ),
    );
  }
}

class _BinderRing extends StatelessWidget {
  final double circleShiftX;
  const _BinderRing({required this.circleShiftX});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Transform.translate(
          offset: Offset(circleShiftX, 0),
          child: Container(
            width: 15,
            height: 15,
            decoration: const BoxDecoration(color: Color(0xFF3E2723), shape: BoxShape.circle),
          ),
        ),
        Container(
          width: 40,
          height: 8,
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(3),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 2, offset: const Offset(1, 1)),
            ],
          ),
        ),
      ],
    );
  }
}
