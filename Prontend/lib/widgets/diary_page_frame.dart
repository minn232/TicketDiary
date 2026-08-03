import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pressable_scale.dart';

/// 다이어리 UI의 공통 프레임(가죽 배경 + 겹친 페이지 레이어 + 바인더 링 + 우측 탭)을
/// 여러 화면에서 재사용하기 위한 래퍼 위젯.
class DiaryPageFrame extends StatelessWidget {
  /// 다이어리 프레임의 가로:세로 비율.
  ///
  /// 원래는 실제 다이어리(A5, 148×210mm) 규격(148/210 ≈ 0.705)을 썼지만,
  /// 다이어리 첫 페이지에 티켓추가 버튼 + 티켓 3개(총 4개, 모두 같은 높이·
  /// 간격)가 들어가려면 그 규격보다 세로로 더 길어야 해서 의도적으로 규격을
  /// 벗어나 늘렸고(5/8), 이후 페이지 크기를 10% 더 키웠습니다(가로 폭은
  /// 화면 너비로 고정되므로 세로 길이만 늘어나 비율이 달라집니다).
  static const double diaryAspectRatio = (5 / 8) / 1.1;

  final Widget child;
  final bool isTabRoot;
  final Color backgroundColor;
  final Color pageColor;
  final List<DiaryPageLayerSpec> pageLayers;
  final List<DiarySideTabSpec> sideTabs;

  /// 이 화면에 실제로 쓰이는 프레임 비율. 기본값은 [diaryAspectRatio]지만,
  /// 특정 화면만 세로로 더/덜 길게 하고 싶으면 이 값을 오버라이드합니다.
  final double aspectRatio;
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

  /// true면 [overlayMainPage]를 페이지 박스가 아닌 프레임 전체 크기로
  /// 배치합니다. 페이지 넘김 잎에 우측 인덱스 탭까지 포함시키고 싶은
  /// 화면(다이어리 메인)에서 씁니다.
  final bool overlayMainPageFullFrame;

  /// 바인더 링은 기본적으로 페이지보다 앞(위)에 그려집니다. 이 notifier가
  /// true를 흘려보내는 동안(페이지 넘김 애니메이션이 진행 중일 때)에만
  /// [overlayMainPage]가 링보다 앞으로 와서, 넘어가는 페이지가 실제로 링
  /// 위를 지나가는 것처럼 보입니다. null이면 항상 링이 앞입니다.
  final ValueListenable<bool>? overlayAnimatingNotifier;

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
    this.aspectRatio = diaryAspectRatio,
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
    this.overlayMainPageFullFrame = false,
    this.overlayAnimatingNotifier,
  });

  Widget _buildOverlayMainPage() {
    if (overlayMainPageVisibleNotifier == null) return overlayMainPage!;
    return ValueListenableBuilder<bool>(
      valueListenable: overlayMainPageVisibleNotifier!,
      builder: (context, visible, _) {
        return visible ? overlayMainPage! : const SizedBox.shrink();
      },
    );
  }

  Widget _buildRing() {
    return Positioned(
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
    );
  }

  Widget _buildOverlayPositioned() {
    return overlayMainPageFullFrame
        ? Positioned.fill(child: _buildOverlayMainPage())
        : Positioned(
            top: pageTop,
            bottom: pageBottom,
            left: pageLeft,
            right: pageRight,
            child: FractionallySizedBox(
              widthFactor: 1.1,
              child: _buildOverlayMainPage(),
            ),
          );
  }

  /// 바인더 링과 페이지 넘김 오버레이를 [overlayAnimatingNotifier] 값에 따라
  /// 순서를 바꿔 그립니다(둘 다 있을 때만 순서가 의미 있음). 애니메이션
  /// 중이 아니면(기본) 링이 앞, 진행 중이면 오버레이가 앞입니다.
  ///
  /// [_buildRing]은 내부에서 [Positioned]를 반환하는데, [Positioned]는
  /// 반드시 [Stack]의 직계 자식이어야 left/top/bottom 값이 해석됩니다.
  /// 그래서 어떤 경우든(오버레이가 없을 때 포함) 항상 [Stack]으로 감싸서
  /// 반환합니다 — 예전엔 오버레이가 없는 화면(소식/결산/설정 등)에서
  /// [_buildRing]을 [Stack] 없이 그대로 반환해, 이 위젯이 감싸이는
  /// [Positioned.fill]의 자식으로 중첩된 [Positioned]가 되면서 바인더 링
  /// 위치(binderLeft/binderTop/binderBottom)가 어긋났습니다.
  Widget _buildRingAndOverlay() {
    if (!showBinderRings) {
      if (overlayMainPage == null) return const SizedBox.shrink();
      return Stack(
        clipBehavior: Clip.none,
        children: [_buildOverlayPositioned()],
      );
    }
    if (overlayMainPage == null) {
      return Stack(clipBehavior: Clip.none, children: [_buildRing()]);
    }

    final notifier = overlayAnimatingNotifier;
    if (notifier == null) {
      // notifier가 없으면 항상 링이 앞(기존 기본 동작).
      return Stack(
        clipBehavior: Clip.none,
        children: [_buildOverlayPositioned(), _buildRing()],
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: notifier,
      builder: (context, animating, _) {
        return Stack(
          clipBehavior: Clip.none,
          children: animating
              ? [_buildRing(), _buildOverlayPositioned()]
              : [_buildOverlayPositioned(), _buildRing()],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
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

        /// 2. 기본 우측 탭들 (종이 뒤에 배치). 활성 탭은 5번 레이어에서
        /// 더 튀어나온 위치에 다시 그리므로 여기서는 그리지 않습니다.
        for (final tab in sideTabs)
          if (!tab.isActive)
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
        ///
        /// 페이지(종이)만 가로로 10% 늘립니다. FractionallySizedBox는
        /// Transform.scale과 달리 실제 레이아웃 폭을 넓히는 것이라, 안의
        /// 글씨/내용이 픽셀 단위로 눌리거나 늘어나지 않고 그 너비에 맞게
        /// 정상 크기로 다시 배치됩니다. 인덱스 탭/바인더 링은 이 바깥
        /// (2, 5, 6번 레이어)에 있어서 영향을 받지 않고 원래 위치 그대로
        /// 화면 안에 남습니다.
        Positioned(
          top: pageTop,
          bottom: pageBottom,
          left: pageLeft,
          right: pageRight,
          child: FractionallySizedBox(
            widthFactor: 1.1,
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
        ),

        /// 4~5. 왼쪽 바인더 링 + 애니메이션용 메인 페이지 오버레이
        ///
        /// 기본은 링이 오버레이보다 앞(원래 디자인 그대로, 링이 페이지 위).
        /// [overlayAnimatingNotifier]가 true인 동안(페이지 넘김 진행 중)만
        /// 오버레이가 앞으로 와서, 넘어가며 들리는 페이지 잎이 그 순간에만
        /// 링 위를 덮으며 지나갑니다. [overlayMainPageFullFrame]이면
        /// 오버레이가 페이지 박스가 아니라 프레임 전체를 차지합니다 —
        /// 넘어가는 페이지 잎에 우측 인덱스 탭까지 붙여서 함께 넘기려면
        /// 오버레이가 탭 영역을 포함해야 하기 때문입니다.
        Positioned.fill(child: _buildRingAndOverlay()),

        /// 6. 활성 탭 레이어 (메인 페이지 종이 위로 드러나는 부분)
        ///
        /// 위치는 2번 레이어의 다른 탭들과 완전히 동일합니다(원래 위치에서
        /// 페이지 쪽으로 더 밀어 넣지 않음). 순서만 메인 페이지(3번)·링·
        /// 오버레이(4~5번)보다 뒤에(=위에) 그려서, 제자리에 그대로 있으면서
        /// 항상 맨 위로 드러나 보이게 합니다.
        for (final tab in activeTabs)
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
      ],
    );

    // 프레임 자체는 aspectRatio(기본값 diaryAspectRatio) 그대로 화면 안에
    // 맞춰 배치합니다. 가로 10% 확대는 페이지(종이) 부분에만 개별적으로
    // 적용되어 있어서(1, 3, 4번 레이어), 인덱스 탭/바인더 링은 여기 영향을
    // 받지 않고 화면 안에 그대로 보입니다.
    final sizedFrame = Center(
      child: AspectRatio(aspectRatio: aspectRatio, child: frame),
    );

    final scaffold = Scaffold(
      backgroundColor: backgroundColor,
      // 기본값(true)이면 키보드가 뜰 때마다 body 높이가 줄어들어, 그
      // 안의 AspectRatio 프레임(다이어리 페이지) 전체가 작아지고 위로
      // 밀립니다. 키보드는 그 위에 그냥 겹쳐서 그려지도록 false로 둡니다.
      resizeToAvoidBottomInset: false,
      body: useSafeArea ? SafeArea(child: sizedFrame) : sizedFrame,
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
  static const double defaultWidth = 45 * 0.7;
  static const double defaultHeight = 90 * 0.7;

  /// [DiaryPageFrame.pageColor] 기본값과 동일. 탭 왼쪽(안쪽) 그라데이션이
  /// 이 색으로 옅어져서, 종이 밑으로 파고든 것처럼 보이게 합니다.
  static const Color defaultPageColor = Color(0xFFF4F1E1);

  final Color color;
  final String text;
  final bool rotateText;
  final double width;
  final double height;
  final BorderRadius borderRadius;
  final TextStyle textStyle;
  final Color pageColor;

  const DiaryIndexTab({
    super.key,
    required this.color,
    required this.text,
    this.rotateText = true,
    this.width = defaultWidth,
    this.height = defaultHeight,
    // 왼쪽(안쪽)은 3, 오른쪽(바깥으로 드러나는 변)은 더 둥글게.
    // 값을 바꾸려면 이 두 Radius.circular(...)를 수정하면 됩니다.
    this.borderRadius = const BorderRadius.horizontal(
      left: Radius.circular(3),
      right: Radius.circular(6),
    ),
    this.textStyle = const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87),
    this.pageColor = defaultPageColor,
  });

  @override
  Widget build(BuildContext context) {
    final label = Text(text, style: textStyle);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: color, borderRadius: borderRadius),
      child: Stack(
        children: [
          Center(
            child: rotateText ? RotatedBox(quarterTurns: 1, child: label) : label,
          ),
          // 왼쪽 가장자리가 페이지 종이 밑으로 파고든 것처럼, 어둡게 대신
          // 페이지 색으로 옅어지는 그라데이션을 줍니다.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    pageColor.withValues(alpha: 0.65),
                    pageColor.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.35],
                ),
              ),
            ),
          ),
        ],
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
      // 페이지(종이)만 가로로 10% 늘리고, 인덱스 탭/바인더 링은 이 변환
      // 바깥에 있어서 영향을 받지 않습니다([DiaryPageFrame.build] 참고).
      child: FractionallySizedBox(
        widthFactor: 1.1,
        child: Container(
          decoration: BoxDecoration(
            color: pageColor,
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(15)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8, offset: const Offset(4, 4)),
            ],
          ),
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
          width: 20,
          height: 12,
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
