import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pressable_scale.dart';

/// 다이어리 UI의 공통 프레임(가죽 배경 + 겹친 페이지 레이어 + 바인더 링 + 우측 탭)을
/// 여러 화면에서 재사용하기 위한 래퍼 위젯.
///
/// 화면별로 달라지는 실제 내용은 [child]로 주입하세요.
class DiaryPageFrame extends StatelessWidget {
  final Widget child;

  /// 탭(다이어리/소식/결산/설정) 루트 화면인지 여부.
  ///
  /// 탭 전환 애니메이션을 살리기 위해(스택에 첫 라우트를 남김),
  /// 탭 화면이 navigator 상에서 첫 라우트가 아닐 수 있습니다.
  /// 이때 시스템 back(안드로이드 등)로 이전 라우트로 돌아가는 UX가 어색해질 수 있어
  /// 탭 루트 화면에서는 back pop을 막고(필요 시 앱 종료)하도록 옵션을 둡니다.
  final bool isTabRoot;

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

  /// 바인더링의 왼쪽 원(원형 파츠)만 가로로 이동시키는 값(px)
  /// - +값: 오른쪽으로 이동
  /// - -값: 왼쪽으로 이동
  final double binderRingCircleShiftX;

  final bool useSafeArea;

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
    // 겹쳐진 페이지 레이어들의 기본 bottom(20)과 맞춰 메인 페이지가 더 길어 보이지 않게
    this.pageBottom = 20,
    this.pageLeft = 30,
    this.pageRight = 45,
    this.showBinderRings = true,
    this.binderRingCount = 6,
    this.binderLeft = 0,
    this.binderTop = 50,
    this.binderBottom = 50,
    this.binderRingCircleShiftX = 8,
    this.useSafeArea = true,
  });

  @override
  Widget build(BuildContext context) {
    // DiaryIndexTab 기본 크기(디자인 변경 시 여기서도 같이 따라가도록 상수 참조)
    const sideTabWidth = DiaryIndexTab.defaultWidth;
    const sideTabHeight = DiaryIndexTab.defaultHeight;

    final activeTabs = sideTabs.where((t) => t.isActive).toList(growable: false);

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
            clipBehavior: Clip.antiAlias,
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

        /// 활성 탭: 현재 페이지에서만 탭의 '왼쪽(페이지 안쪽으로 들어가는) 영역'이
        /// 메인 페이지 위로 드러나도록 한 번 더 그립니다.
        ///
        /// - 탭 디자인(색/그림자/크기)은 그대로 유지
        /// - 위치(right/top)는 기존 tab.right/top 그대로
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
                  // 페이지 오른쪽 경계(pageRight)와 탭의 right(tab.right) 차이만큼은
                  // 탭이 페이지 밖(오른쪽)으로 튀어나온 영역이므로,
                  // 그 부분을 제외한 '안쪽(왼쪽) 영역'만 보이게 합니다.
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

        /// 왼쪽 바인더 링
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

    // 탭 루트 화면에서는 back으로 이전 라우트(예: 초기 라우트)로 돌아가지 않게 막습니다.
    // 안드로이드에서는 앱 종료 동작을 유도합니다.
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

  /// 현재(활성) 페이지에 해당하는 인덱스 탭인지 여부
  /// - 활성 탭은 메인 페이지 '앞'으로 일부 영역만 드러나도록 처리
  final bool isActive;

  const DiarySideTabSpec({
    required this.right,
    required this.top,
    required this.child,
    this.onTap,
    this.isActive = false,
  });
}

/// 공용 인덱스 탭 위젯
class DiaryIndexTab extends StatelessWidget {
  /// 기본 스티커 크기(프로젝트 전반에서 동일하게 쓰기 위해 상수로 노출)
  /// - 요청사항: 기존 디자인 유지 + 약 5px 정도 크기 증가
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

    // 요청사항: 왼쪽 모서리도 둥글게(스티커 느낌 강화)
    this.borderRadius = const BorderRadius.horizontal(
      left: Radius.circular(10),
      right: Radius.circular(5),
    ),
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


