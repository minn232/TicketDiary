import 'package:flutter/material.dart';

import 'pressable_scale.dart';

/// 다이어리 UI의 공통 프레임(가죽 배경 + 겹친 페이지 레이어 + 바인더 링 + 우측 탭)을
/// 여러 화면에서 재사용하기 위한 래퍼 위젯.
///
/// 화면별로 달라지는 실제 내용은 [child]로 주입하세요.
class DiaryPageFrame extends StatelessWidget {
  final Widget child;

  /// 배경(가죽) 색상
  final Color backgroundColor;

  /// 메인 페이지 종이 색상
  final Color pageColor;

  /// 겹쳐진 페이지 레이어 스펙
  final List<DiaryPageLayerSpec> pageLayers;

  /// 우측 탭 스펙
  final List<DiarySideTabSpec> sideTabs;

  /// 메인 페이지(실제 내용이 들어가는 페이지) 위치 여백
  final double pageTop;
  final double pageBottom;
  final double pageLeft;
  final double pageRight;

  /// 바인더 링 위치/개수
  final bool showBinderRings;
  final int binderRingCount;
  final double binderLeft;
  final double binderTop;
  final double binderBottom;

  final bool useSafeArea;

  const DiaryPageFrame({
    super.key,
    required this.child,
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
    this.pageBottom = 10,
    this.pageLeft = 30,
    this.pageRight = 45,
    this.showBinderRings = true,
    this.binderRingCount = 6,
    this.binderLeft = 15,
    this.binderTop = 50,
    this.binderBottom = 50,
    this.useSafeArea = true,
  });

  @override
  Widget build(BuildContext context) {
    final frame = Stack(
      children: [
        /// 뒤쪽 페이지 레이어들
        for (final layer in pageLayers)
          _DiaryPageLayer(
            right: layer.right,
            bottom: layer.bottom,
            pageColor: pageColor,
            pageTop: pageTop,
            pageLeft: pageLeft,
          ),

        /// 우측 탭들
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

        /// 실제 컨텐츠가 들어가는 메인 페이지
        Positioned(
          top: pageTop,
          bottom: pageBottom,
          left: pageLeft,
          right: pageRight,
          child: Container(
            decoration: BoxDecoration(
              color: pageColor,
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(15),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 10,
                  offset: const Offset(5, 5),
                ),
              ],
            ),
            child: child,
          ),
        ),

        /// 왼쪽 바인더 링
        if (showBinderRings)
          Positioned(
            left: binderLeft,
            top: binderTop,
            bottom: binderBottom,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(binderRingCount, (index) => const _BinderRing()),
            ),
          ),
      ],
    );

    return Scaffold(
      backgroundColor: backgroundColor,
      body: useSafeArea ? SafeArea(child: frame) : frame,
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

  const DiarySideTabSpec({
    required this.right,
    required this.top,
    required this.child,
    this.onTap,
  });
}

/// 공용 인덱스 탭 위젯
class DiaryIndexTab extends StatelessWidget {
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
    this.width = 40,
    this.height = 85,
    this.borderRadius = const BorderRadius.horizontal(right: Radius.circular(5)),
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
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(15),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(4, 4),
            ),
          ],
        ),
      ),
    );
  }
}

class _BinderRing extends StatelessWidget {
  const _BinderRing();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 15,
          height: 15,
          decoration: const BoxDecoration(color: Color(0xFF3E2723), shape: BoxShape.circle),
        ),
        Container(
          width: 25,
          height: 6,
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

