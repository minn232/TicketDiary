import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pressable_scale.dart';
import 'responsive_text.dart';

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

  /// 바인더 링 기본 배치값들. [DiaryPageFlipper]가 다음/이전 페이지 미리보기에
  /// 얹는 정적 링([BinderRingColumn])도 이 값들을 그대로 참조해서, 실제
  /// 프레임이 그리는 링과 완전히 같은 자리에 겹치도록 맞춥니다.
  static const int defaultBinderRingCount = 6;
  static const double defaultBinderTop = 50;
  static const double defaultBinderBottom = 50;

  /// 원(그로밋)의 지름은 항상 은색 막대의 세로 길이(barHeight)보다 이
  /// 비율만큼 큽니다 — 막대가 페이지 크기에 비례해 커지거나 작아져도
  /// 원이 막대 굵기에 맞게 자연스럽게 같이 조절됩니다([_BinderRing] 참고).
  static const double binderCircleToBarHeightRatio = 1.2;

  /// 은색 막대의 크기를 페이지 크기에 비례하게 잡습니다(고정 픽셀값 대신).
  /// 가로는 페이지 폭의 7%, 세로는 페이지 높이의 2%.
  static const double binderBarWidthRatio = 0.07;
  static const double binderBarHeightRatio = 0.02;

  /// 막대 그림자(offset(2,2) + blurRadius 5 + spreadRadius 0.5)가 막대
  /// 오른쪽으로 번지는 만큼의 여유 공간. [_buildRing]의 ClipRect가 이
  /// 여유 공간까지 포함해서 잘라내도록, [BinderRingColumn] 오른쪽에 이만큼
  /// 투명 패딩을 둡니다.
  static const double defaultBinderShadowMargin = 15;

  /// 프레임 크기(frameWidth/frameHeight)를 바탕으로 은색 막대의 크기와,
  /// 막대·원의 가로 위치를 계산합니다. [DiaryPageFrame]의 실제 링과
  /// [DiaryPageFlipper]의 정적 링 사본이 이 함수를 공유해서 완전히 같은
  /// 자리·크기를 유지합니다.
  ///
  /// - 막대 크기: 페이지 폭의 [binderBarWidthRatio], 페이지 높이의
  ///   [binderBarHeightRatio]([_BinderRing] 참고).
  /// - 막대 위치: 막대의 가로 절반이 페이지에 걸치도록 — 막대의 가로
  ///   중심이 페이지의 실제 렌더링된 왼쪽 끝(pageLeft에서 가로 10% 확대로
  ///   밀려난 만큼을 뺀 위치)과 만납니다.
  /// - 원 위치: 바인더 링(원)의 가로 절반이 은색 막대의 왼쪽 끝에 닿도록
  ///   — 원의 가로 중심이 막대의 왼쪽 끝과 만납니다([_BinderRing]의
  ///   `circleShiftX`로 적용됨).
  static ({
    double barWidth,
    double barHeight,
    double circleShiftX,
    double binderLeft,
    double pivotX,
    double pageWidth,
  }) computeRingMetrics({
    required double frameWidth,
    required double frameHeight,
    double pageTop = defaultPageTop,
    double pageBottom = defaultPageBottom,
    double pageLeft = defaultPageLeft,
    double pageRight = defaultPageRight,
  }) {
    final pageBoxWidth = frameWidth - pageLeft - pageRight;
    final pageWidth = pageBoxWidth * defaultPageWidthFactor;
    final pageHeight = frameHeight - pageTop - pageBottom;
    // FractionallySizedBox(widthFactor: defaultPageWidthFactor)가 기본
    // 중앙 정렬로 늘어나므로, 늘어난 폭의 절반만큼 pageLeft보다 왼쪽으로
    // 밀려난 지점이 페이지의 실제 렌더링된 왼쪽 끝입니다. [DiaryPageFlipper]가
    // 회전축(pivotX)으로 쓰는 값과 수학적으로 같습니다.
    final pageActualLeft = pageLeft - (defaultPageWidthFactor - 1) / 2 * pageBoxWidth;

    // 기존 비례 계산값에 5px을 더해 막대를 조금 더 길게 만듭니다.
    // binderLeft가 barWidth로부터 계산되므로(막대 중심이 항상 pivotX에
    // 오도록), 길이가 늘어난 만큼 위치도 자동으로 왼쪽으로 더 밀려서
    // 막대 중심은 그대로 유지됩니다.
    final barWidth = pageWidth * binderBarWidthRatio + 5;
    final barHeight = pageHeight * binderBarHeightRatio;
    final circleDiameter = barHeight * binderCircleToBarHeightRatio;
    final circleShiftX = circleDiameter / 2;
    final binderLeft = pageActualLeft - circleDiameter - barWidth / 2;

    return (
      barWidth: barWidth,
      barHeight: barHeight,
      circleShiftX: circleShiftX,
      binderLeft: binderLeft,
      pivotX: pageActualLeft,
      pageWidth: pageWidth,
    );
  }

  /// 페이지(종이) 박스 기본 배치값들. [DiaryPageFlipper]가 넘어가는 잎 뒤에
  /// 항상 그리는 정적 그림자([DiaryPageFlipper._buildStaticPageShadow])도
  /// 이 값들을 그대로 참조해서, diary_screen.dart의 `_buildFlipLeaf`가
  /// 그리는 실제 페이지 박스와 완전히 같은 자리·크기를 유지합니다.
  static const double defaultPageTop = 10;
  static const double defaultPageBottom = 20;
  static const double defaultPageLeft = 30;
  static const double defaultPageRight = 45;
  // 페이지를 기존보다 가로로 5% 작게(1.1 -> 1.1*0.95) — 오른쪽 인덱스
  // 탭이 상대적으로 작아 보인다는 요청으로, 페이지를 살짝 줄이고 그만큼
  // 확보된 공간에 탭을 키웠습니다([DiaryIndexTab.defaultWidth]/[defaultHeight] 참고).
  static const double defaultPageWidthFactor = 1.1 * 0.95;
  static const BorderRadius defaultPageBorderRadius = BorderRadius.horizontal(right: Radius.circular(15));

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
  final double binderTop;
  final double binderBottom;
  final bool useSafeArea;
  final bool animateMainPage;
  final Widget? overlayMainPage;
  final ValueListenable<bool>? overlayMainPageVisibleNotifier;

  /// true면 [overlayMainPage]를 페이지 박스가 아닌 프레임 전체 크기로
  /// 배치합니다. 페이지 넘김 잎에 우측 인덱스 탭까지 포함시키고 싶은
  /// 화면(다이어리 메인)에서 씁니다.
  final bool overlayMainPageFullFrame;

  /// 페이지 넘김 진행도(0.0~1.0)를 흘려보내면, 그 속도 그대로 바인더
  /// 링이 오른쪽부터 사라졌다가(진행도가 커질수록) 넘김이 끝나(0으로
  /// 돌아가면) 다시 나타납니다. null이면 링은 항상 그대로 보입니다.
  final ValueListenable<double>? overlayFlipProgress;

  /// 우측 인덱스 탭(활성/비활성 모두)의 불투명도(0.0~1.0)를 실시간으로
  /// 흘려보냅니다. null이면 항상 1.0(완전 불투명, 기존 동작)입니다. 소식
  /// 탭이 찜/아티스트 패널로 전환될 때 탭을 서서히 숨겨(몰입감) 페이지
  /// 조각(풀탭)으로만 오가도록 하려고 씁니다 — 0에 가까워지면 자동으로
  /// 탭 눌림도 막습니다([IgnorePointer]).
  final ValueListenable<double>? sideTabsOpacity;

  /// 메인 페이지(종이) "뒤"에 끼워 넣는 자유 레이어. 우측 인덱스 탭이
  /// 페이지 오른쪽 경계 밖으로만 삐져나와 보이듯, 이 레이어도 페이지에
  /// 가려지고 페이지 밖(예: 상단 경계 위) 부분만 보입니다 — 페이지 뒤에서
  /// 끼워 올린 "손잡이(풀탭 조각)"처럼 보이게 하려고 씁니다.
  /// [Positioned.fill]로 프레임 전체 크기를 받으며, 내부에서
  /// [DiaryPageFrame.computeRingMetrics]로 페이지 위치를 계산해 배치합니다.
  /// 프레임 밖 여백까지 그릴 수 있도록 스택은 [Clip.none]입니다.
  final Widget? frameBehindPage;

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
    this.pageTop = defaultPageTop,
    this.pageBottom = defaultPageBottom,
    this.pageLeft = defaultPageLeft,
    this.pageRight = defaultPageRight,
    this.showBinderRings = true,
    this.binderRingCount = defaultBinderRingCount,
    this.binderTop = defaultBinderTop,
    this.binderBottom = defaultBinderBottom,
    this.useSafeArea = true,
    this.animateMainPage = false,
    this.overlayMainPage,
    this.overlayMainPageVisibleNotifier,
    this.overlayMainPageFullFrame = false,
    this.overlayFlipProgress,
    this.sideTabsOpacity,
    this.frameBehindPage,
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

  /// [revealFraction](0.0~1.0)만큼만 왼쪽부터 보여주고 나머지(오른쪽)는
  /// 잘라냅니다 — 1.0이면 평소처럼 전체가 보이고, 0에 가까울수록 오른쪽부터
  /// 사라진 것처럼 보입니다. [showBar]/[showCircle]로 막대와 원을 서로 다른
  /// z순서 레이어로 나눠 그릴 수 있습니다([_buildRingAndOverlay] 참고).
  Widget _buildRing(
    double frameWidth,
    double frameHeight, {
    double revealFraction = 1.0,
    bool showBar = true,
    bool showCircle = true,
  }) {
    final metrics = computeRingMetrics(
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      pageTop: pageTop,
      pageBottom: pageBottom,
      pageLeft: pageLeft,
      pageRight: pageRight,
    );
    return Positioned(
      left: metrics.binderLeft,
      top: binderTop,
      bottom: binderBottom,
      child: ClipRect(
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: revealFraction.clamp(0.0, 1.0),
          // Align의 widthFactor는 자식(막대)의 "레이아웃" 폭만 기준으로
          // 계산되는데, 그 폭엔 그림자(boxShadow)의 번짐(blur+offset)이
          // 포함되지 않습니다. revealFraction=1.0(전체 보임)이어도 이
          // ClipRect가 막대의 딱 그 레이아웃 폭까지만 잘라내서, 오른쪽으로
          // 번져야 할 그림자가 항상 세로 일자로 잘려 보였습니다("은색 막대
          // 오른쪽이 살짝 잘려 보인다"는 제보의 실제 원인). 오른쪽에
          // 그림자가 들어갈 여유 공간(투명 패딩)을 미리 확보해서, 그
          // 공간까지 포함한 폭을 기준으로 잘리게 합니다.
          child: Padding(
            padding: const EdgeInsets.only(right: defaultBinderShadowMargin),
            child: BinderRingColumn(
              count: binderRingCount,
              circleShiftX: metrics.circleShiftX,
              barWidth: metrics.barWidth,
              barHeight: metrics.barHeight,
              showBar: showBar,
              showCircle: showCircle,
            ),
          ),
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
              widthFactor: defaultPageWidthFactor,
              child: _buildOverlayMainPage(),
            ),
          );
  }

  /// 바인더 링과 페이지 넘김 오버레이를 함께 그립니다. 원(그로밋)과 은색
  /// 막대는 서로 다른 z순서를 갖습니다 — 원은 항상 넘어가는 페이지
  /// 뒤(아래)에 있어서(잎의 왼쪽 여백은 투명이라, 잎이 실제로 덮지 않는
  /// 부분에서는 뒤의 원이 그대로 비쳐 보입니다), 막대는 원래대로 항상
  /// 페이지 앞(위)에 있습니다. [overlayFlipProgress]가 있으면 그 진행도에
  /// 맞춰 막대가 오른쪽부터 사라졌다가 다시 나타납니다 — 앞으로 넘기기
  /// (진행도 0 이상, 정지 상태 포함)는 보이는 채로 시작해 사라지고, 뒤로
  /// 넘기기(진행도 음수)는 반대로 숨겨진 채로 시작해 넘김이 끝나면 다시
  /// 나타납니다.
  ///
  /// [_buildRing]은 내부에서 [Positioned]를 반환하는데, [Positioned]는
  /// 반드시 [Stack]의 직계 자식이어야 left/top/bottom 값이 해석됩니다.
  /// 그래서 어떤 경우든(오버레이가 없을 때 포함) 항상 [Stack]으로 감싸서
  /// 반환합니다 — 예전엔 오버레이가 없는 화면(소식/결산/설정 등)에서
  /// [_buildRing]을 [Stack] 없이 그대로 반환해, 이 위젯이 감싸이는
  /// [Positioned.fill]의 자식으로 중첩된 [Positioned]가 되면서 바인더 링
  /// 위치(binderTop/binderBottom, 그리고 계산되는 가로 위치)가 어긋났습니다.
  Widget _buildRingAndOverlay(double frameWidth, double frameHeight) {
    if (!showBinderRings) {
      if (overlayMainPage == null) return const SizedBox.shrink();
      return Stack(
        clipBehavior: Clip.none,
        children: [_buildOverlayPositioned()],
      );
    }
    if (overlayMainPage == null) {
      return Stack(clipBehavior: Clip.none, children: [_buildRing(frameWidth, frameHeight)]);
    }

    final progress = overlayFlipProgress;
    final metrics = computeRingMetrics(
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      pageTop: pageTop,
      pageBottom: pageBottom,
      pageLeft: pageLeft,
      pageRight: pageRight,
    );
    // 원(그로밋)은 넘어가는 페이지 뒤에 있어서 애니메이션에 반응해 잘릴
    // 필요가 없습니다(잎이 알아서 덮어줍니다) — 항상 전체가 보입니다.
    final ringCircle = _buildRing(frameWidth, frameHeight, showBar: false);
    // 막대는 페이지 앞에 있어서, 진행도에 맞춰 오른쪽부터 사라졌다가
    // 다시 나타나야 뒤에서 넘어가는 잎이 드러나 보입니다(예전 동작 그대로).
    final ringBar = progress == null
        ? _buildRing(frameWidth, frameHeight, showCircle: false)
        : ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, value, _) {
              // 오른쪽부터 사라지되, 완전히 없어지지 않고 딱 절반(가운데)
              // 까지만 사라집니다. 0 이상이면(앞으로 넘기기 또는 정지)
              // value 0~0.5 구간(잎이 실제로 보이는 구간, progress<=0.5에서
              // 사라짐)에서만 1.0->0.5로 줄어들고, 그 이후(0.5~1.0, 잎은
              // 이미 사라지고 다음 페이지가 바닥에 깔린 채로 남은 시간)는
              // 곧바로 1.0(전체 보임)으로 스냅합니다 — 예전엔 이 뒷부분
              // 구간에서도 계속 0.75->0.5로 줄어들다가 넘김이 완전히 끝난
              // 뒤에야 갑자기 1.0으로 튀어서, "페이지는 이미 다 넘어갔는데
              // 링이 왼쪽 끝까지 계속 사라지다가 뒤늦게 전체 보임으로
              // 나타나는" 것처럼 보였습니다. 음수면(뒤로 넘기기) 반대로
              // 절반만 보이는 채로 시작해서 넘김이 끝나면 다시 완전히
              // 나타납니다.
              if (value > 0.5) {
                // 잎은 이미 사라지고 다음 페이지가 바닥에 깔린 채로 남은
                // 시간 — 아래 추가 페이드 계산 없이 곧바로 1.0(전체 보임)
                // 으로 스냅합니다. uf=1(잎이 사라지는 순간, 바로 이 분기의
                // 시작점)에서 아래 pastHalfFraction 계산은 정확히 0이 되도록
                // 설계돼 있어(막대가 이미 다 사라진 뒤), 여기서 1.0으로
                // 튀는 시점과 자연스럽게 이어집니다.
                return _buildRing(frameWidth, frameHeight, revealFraction: 1.0, showCircle: false);
              }
              final baseReveal = value >= 0 ? 1.0 - value : 0.5 * (1.0 - value);

              // 여기에 더해, 넘어가는 잎의 오른쪽 경계가 실제로 은색 막대의
              // 절반(중앙)을 지나간 뒤부터는 그 지나간 만큼 막대를 추가로
              // 더 사라지게 합니다. edgeX는 그 경계의 근사 x좌표로,
              // [DiaryPageFlipper._buildForwardScene]/[_buildBackwardScene]의
              // angle/translateX 공식과 같은 식으로 구합니다(행별 휨/모서리
              // 리드는 무시 — 잎이 거의 다 사라져 책등에 가까워질 때는
              // bend/cornerLead도 0에 수렴해 이 근사가 실제와 거의
              // 일치합니다).
              final uf = value >= 0 ? value / 0.5 : (1.0 + value).clamp(0.0, 1.0);
              final maxTranslateX = metrics.barWidth * 0.5;
              final translatePhase = ((uf - 0.5) / 0.5).clamp(0.0, 1.0);
              final translateX = -maxTranslateX * translatePhase;
              final edgeX = metrics.pivotX + translateX + metrics.pageWidth * math.cos(uf * math.pi / 2);

              // 막대는 중심이 pivotX에 오도록 배치되므로(computeRingMetrics
              // 참고), 절반(중앙)은 pivotX, 왼쪽 끝은 pivotX - barWidth/2
              // 입니다. edgeX가 아직 중앙에 못 미쳤으면(막대보다 오른쪽)
              // 1.0으로 묶여 영향이 없고, 중앙을 지나 막대 왼쪽 끝까지 다
              // 지나가면(=잎이 막대를 완전히 덮으면) 0이 됩니다 — 이 지점은
              // (설계상) uf=1(잎이 사라지는 순간, 즉 페이지를 다 넘기기
              // 전)과 같거나 그보다 먼저 옵니다.
              final barHalfWidth = metrics.barWidth / 2;
              final pastHalfFraction = barHalfWidth <= 0
                  ? 1.0
                  : ((edgeX - (metrics.pivotX - barHalfWidth)) / barHalfWidth).clamp(0.0, 1.0);

              // 두 효과를 곱해서 합칩니다 — 잎이 아직 막대 절반에 못
              // 미쳤으면(pastHalfFraction=1.0) 기존 페이드만 그대로 적용되고,
              // 절반을 지난 뒤부터는 지나간 비율만큼 추가로 더 사라집니다.
              final revealFraction = baseReveal * pastHalfFraction;
              return _buildRing(frameWidth, frameHeight, revealFraction: revealFraction, showCircle: false);
            },
          );

    return Stack(
      clipBehavior: Clip.none,
      children: [ringCircle, _buildOverlayPositioned(), ringBar],
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeTabs = sideTabs.where((t) => t.isActive).toList(growable: false);

    // 바깥쪽 LayoutBuilder: AspectRatio가 실제로 제약받기 전, 이 프레임에
    // 배정된 전체 폭(availableWidth)을 잽니다. 아이패드처럼 화면 비율이
    // diaryAspectRatio보다 넓은 기기에서는 AspectRatio가 이 폭을 다 쓰지
    // 못하고(세로가 먼저 꽉 참) 프레임 좌우로 갈색 여백이 남는데, 그 여백
    // 폭을 알아내기 위해 안쪽 LayoutBuilder(실제 프레임 폭)와 비교합니다.
    final sizedFrame = LayoutBuilder(
      builder: (context, outerConstraints) {
        final availableWidth = outerConstraints.maxWidth;
        return Center(
          child: AspectRatio(
            aspectRatio: aspectRatio,
            // 안쪽 LayoutBuilder: 프레임의 실제 렌더링 폭(availableWidth와
            // 달리, AspectRatio가 실제로 정한 크기). 이 폭을 기준으로 글자
            // 확대 배율을 계산해 하위 트리 전체(페이지 내용·탭·바인더 링
            // 등)에 전달합니다. 아이폰과 아이패드는 프레임 폭 차이가 커서
            // (다이어리 프레임이 항상 화면 폭에 맞춰짐), 고정 fontSize를
            // 그대로 쓰면 아이패드에서 상대적으로 글자가 너무 작아 보였습니다.
            child: LayoutBuilder(
              builder: (context, innerConstraints) {
                final frameWidth = innerConstraints.maxWidth;
                final scale = (frameWidth / kReferenceFrameWidth)
                    .clamp(kMinTextScale, kMaxTextScale);
                // Center가 좌우로 똑같이 나눠 배치하므로, 한쪽 여백은
                // 전체 차이의 절반입니다. 화면 비율이 diaryAspectRatio보다
                // 좁은 기기(대부분의 폰)에서는 차이가 0(또는 음수 반올림
                // 오차)이라 0으로 묶습니다.
                final marginEachSide =
                    math.max(0.0, (availableWidth - frameWidth) / 2);
                return DiaryFrameScale(
                  scale: scale,
                  marginEachSide: marginEachSide,
                  child: _buildFrameStack(activeTabs, scale, marginEachSide),
                );
              },
            ),
          ),
        );
      },
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

  Widget _buildFrameStack(
    List<DiarySideTabSpec> activeTabs,
    double scale,
    double marginEachSide,
  ) {
    return Stack(
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

        /// 2. 기본 우측 탭들 (종이 뒤에 배치). 활성 탭은 6번 레이어에서
        /// 다시 그리므로 여기서는 그리지 않습니다.
        for (final tab in sideTabs)
          if (!tab.isActive)
            buildScaledSideTab(tab, scale, marginEachSide, opacity: sideTabsOpacity),

        /// 2.5. 페이지 뒤 자유 레이어(풀탭 손잡이 등). 메인 페이지(3번)보다
        /// 먼저(=아래) 그려서, 페이지에 가려지고 페이지 밖으로 삐져나온
        /// 부분만 보이게 합니다 — 우측 인덱스 탭과 같은 원리입니다.
        if (frameBehindPage != null) Positioned.fill(child: frameBehindPage!),

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
            widthFactor: defaultPageWidthFactor,
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
        /// 원(그로밋)은 항상 오버레이(페이지) 뒤, 은색 막대는 항상 오버레이
        /// 앞입니다 — 자세한 내용은 [_buildRingAndOverlay] 참고.
        /// [overlayMainPageFullFrame]이면 오버레이가 페이지 박스가 아니라
        /// 프레임 전체를 차지합니다 — 넘어가는 페이지 잎에 우측 인덱스
        /// 탭까지 붙여서 함께 넘기려면 오버레이가 탭 영역을 포함해야
        /// 하기 때문입니다.
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) =>
                _buildRingAndOverlay(constraints.maxWidth, constraints.maxHeight),
          ),
        ),

        /// 6. 활성 탭 레이어 (메인 페이지 종이 위로 드러나는 부분)
        ///
        /// 위치는 2번 레이어의 다른 탭들과 완전히 동일합니다(원래 위치에서
        /// 페이지 쪽으로 더 밀어 넣지 않음). 순서만 메인 페이지(3번)·링·
        /// 오버레이(4~5번)보다 뒤에(=위에) 그려서, 제자리에 그대로 있으면서
        /// 항상 맨 위로 드러나 보이게 합니다.
        for (final tab in activeTabs)
          buildScaledSideTab(tab, scale, marginEachSide, opacity: sideTabsOpacity),
      ],
    );
  }

  /// 인덱스 탭 하나를 실제 프레임 배율에 맞게 키워서 배치합니다.
  ///
  /// [tab.right]/[tab.top]과 [DiaryIndexTab]의 기본 크기는 전부 아이폰 17
  /// 기준(스케일 없는) 디자인값입니다. 탭을 그냥 그 자리에서 [scale]배
  /// 키우면 탭의 왼쪽 끝이 원래보다 더 페이지 안쪽으로 파고들어(오른쪽
  /// 여백 pageRight=45를 넘어) 페이지 밑에 가려 보이지도, 눌리지도 않는
  /// 문제가 있었습니다. 대신 탭의 왼쪽 끝(=페이지를 침범하는 경계)은
  /// 원래 위치([xLeftOriginal], 항상 pageRight보다 작아 안전)에 고정해
  /// 두고, 커지는 만큼은 반대쪽(프레임 오른쪽 가장자리 밖, [marginEachSide]
  /// 만큼 남는 갈색 여백)으로 튀어나가게 합니다. 아이폰처럼 여백이 없는
  /// (marginEachSide=0) 기기에서는 자연히 원래 자리 그대로 유지됩니다.
  ///
  /// [_buildFrameStack]의 기본(프레임 고정) 탭들 외에, 넘어가는 페이지에
  /// 붙어 별도 트리 경로로 그려지는 "다이어리" 활성 탭([diary_screen.dart]의
  /// `_buildActiveTab`)도 같은 크기·위치 규칙을 따라야 하므로 static으로
  /// 공개해 재사용합니다.
  static Widget buildScaledSideTab(
    DiarySideTabSpec tab,
    double scale,
    double marginEachSide, {
    ValueListenable<double>? opacity,
  }) {
    final scaledWidth = DiaryIndexTab.defaultWidth * scale;
    final scaledHeight = DiaryIndexTab.defaultHeight * scale;
    final xLeftOriginal = tab.right + DiaryIndexTab.defaultWidth;
    var scaledRight = xLeftOriginal - scaledWidth;
    if (-scaledRight > marginEachSide) {
      scaledRight = -marginEachSide;
    }
    final sizedChild = SizedBox(width: scaledWidth, height: scaledHeight, child: tab.child);
    Widget content = tab.onTap == null
        ? sizedChild
        : PressableScale(
            onTap: tab.onTap,
            pressScale: 0.985,
            tapScale: 1.03,
            child: sizedChild,
          );
    if (opacity != null) {
      // 불투명도가 0에 가까워지면 탭이 사실상 사라진 것이므로, 그 동안엔
      // 눌림도 막아 실수로 다른 탭으로 전환되지 않게 합니다.
      content = ValueListenableBuilder<double>(
        valueListenable: opacity,
        builder: (context, value, child) {
          final v = value.clamp(0.0, 1.0);
          return IgnorePointer(
            ignoring: v < 0.05,
            child: Opacity(opacity: v, child: child),
          );
        },
        child: content,
      );
    }
    return Positioned(
      right: scaledRight,
      top: tab.top * scale,
      child: content,
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
  // 페이지를 가로로 5% 줄이면서 확보된 공간만큼 탭을 키움(0.7 -> 0.8,
  // 약 14% 확대).
  static const double defaultWidth = 45 * 0.8;
  static const double defaultHeight = 90 * 0.8;

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
    // textStyle의 fontSize는 (기본값이든 커스텀이든) 항상 아이폰 17 기준
    // 디자인값이라고 가정하고, 실제 사용하는 자리에서(= context가 있는
    // 여기서) 프레임 크기에 맞게 확대/축소합니다. 생성자 기본값 자체는
    // const라 여기서 직접 계산할 수 없습니다. width/height는 여기서
    // 스케일하지 않습니다 — 호출부(diary_tabs.dart)가 탭이 드러나는 여백
    // 안에 들어가도록 상한을 씌운 배율로 이미 계산해서 넘깁니다.
    final label = Text(
      text,
      style: textStyle.copyWith(fontSize: context.sp(textStyle.fontSize ?? 13)),
    );
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
        widthFactor: DiaryPageFrame.defaultPageWidthFactor,
        child: Container(
          decoration: BoxDecoration(
            color: pageColor,
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(15)),
            // 맨 뒤(1번째) 장은 갈색 배경과 맞닿아 있어 그림자 없이도 경계가
            // 뚜렷하지만, 2~4번째 장은 바로 앞장과 같은 페이지 색(크림)이라
            // 그림자만으로 경계를 만들어야 해서 상대적으로 흐리게 보였습니다
            // — 장마다 배경이 달라 그림자 "느낌"이 일정하지 않던 원인.
            // 얇은 테두리를 추가해 배경이 갈색이든 크림색이든 모든 장의
            // 경계가 동일하게 또렷이 보이도록 맞춥니다.
            border: Border.all(color: Colors.black.withValues(alpha: 0.15), width: 1),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8, offset: const Offset(4, 4)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 바인더 링 여러 개를 세로로 나열한 디자인. [DiaryPageFrame]의 실제(진행도에
/// 반응하는) 링과, [DiaryPageFlipper]가 다음/이전 페이지 미리보기에 얹는
/// 정적인 링이 이 위젯을 공유해서 완전히 같은 모양을 유지합니다.
class BinderRingColumn extends StatelessWidget {
  final int count;
  final double circleShiftX;
  final double barWidth;
  final double barHeight;

  /// false면 은색 막대 없이 원(그로밋)만 그립니다. [DiaryPageFrame]이 원과
  /// 막대를 서로 다른 z순서 레이어로 나눠 그릴 때(원은 넘어가는 페이지
  /// 뒤에, 막대는 앞에) 씁니다.
  final bool showBar;

  /// false면 원(그로밋) 없이 은색 막대만 그립니다. [showBar]와 같은 이유로
  /// 씁니다.
  final bool showCircle;

  const BinderRingColumn({
    super.key,
    required this.count,
    required this.circleShiftX,
    required this.barWidth,
    required this.barHeight,
    this.showBar = true,
    this.showCircle = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(
        count,
        (index) => _BinderRing(
          circleShiftX: circleShiftX,
          barWidth: barWidth,
          barHeight: barHeight,
          showBar: showBar,
          showCircle: showCircle,
        ),
      ),
    );
  }
}

class _BinderRing extends StatelessWidget {
  final double circleShiftX;
  final double barWidth;
  final double barHeight;
  final bool showBar;
  final bool showCircle;
  const _BinderRing({
    required this.circleShiftX,
    required this.barWidth,
    required this.barHeight,
    required this.showBar,
    required this.showCircle,
  });
  @override
  Widget build(BuildContext context) {
    // 원(그로밋) 지름은 항상 막대 세로 길이(barHeight)보다
    // [DiaryPageFrame.binderCircleToBarHeightRatio]배 큽니다. [circleShiftX]도
    // (computeRingMetrics에서) 이 값을 기준으로 계산돼 있어서, 여기서도
    // 반드시 같은 식을 써야 원의 중심 위치(=막대 왼쪽 끝)가 어긋나지
    // 않습니다.
    final circleDiameter = barHeight * DiaryPageFrame.binderCircleToBarHeightRatio;
    return Row(
      // 기본값(max)이면 Row가 부모가 주는 최대 폭을 그대로 차지해버려서,
      // _buildRing의 Align(widthFactor:)이 실제 링 폭(원 지름 + 막대 폭)이
      // 아니라 그 큰 폭을 기준으로 잘리는 지점을 계산하게 됩니다 — 그러면
      // 진행도와 실제로 보이는 정도가 안 맞아서(진행도가 꽤 진행돼야 겨우
      // 잘리기 시작하다가 막판에 갑자기 확 잘리는 식으로) 어긋나 보입니다.
      // min으로 실제 내용 폭만큼만 차지하게 고정합니다.
      mainAxisSize: MainAxisSize.min,
      children: [
        // showCircle이 false여도(막대만 그리는 레이어) 이 칸의 레이아웃
        // 폭은 항상 차지해 둡니다 — 그래야 뒤에 오는 막대의 가로 위치가
        // 원이 있을 때와 똑같이 유지됩니다(원을 아예 빼면 막대가 원 폭만큼
        // 왼쪽으로 밀려 보입니다).
        //
        // circleDiameter(=barHeight*1.2)가 barHeight보다 항상 크기 때문에,
        // 원 Container를 그냥 두면 이 Row의 세로 크기(cross-axis)가 barHeight가
        // 아니라 circleDiameter로 커져서, BinderRingColumn의 spaceEvenly가
        // 그만큼 줄어든 간격으로 6개 링을 다시 배치해버립니다 — 원이 커진
        // 만큼 전체 링들의 세로 위치가 조금씩 밀리는 부작용이 있었습니다.
        // SizedBox(height: barHeight)로 이 칸이 Row에 "보고하는" 레이아웃
        // 높이를 원래(막대 높이)대로 고정해두고, 그 안의 OverflowBox가 실제
        // 원은 circleDiameter 그대로 그리되 위아래로 튀어나오게(overflow)
        // 해서, 세로 위치는 전혀 안 바뀌면서 원만 커진 것처럼 보이게 합니다.
        Transform.translate(
          offset: Offset(circleShiftX, 0),
          child: SizedBox(
            width: circleDiameter,
            height: barHeight,
            child: OverflowBox(
              minWidth: circleDiameter,
              maxWidth: circleDiameter,
              minHeight: circleDiameter,
              maxHeight: circleDiameter,
              child: Container(
                width: circleDiameter,
                height: circleDiameter,
                decoration: showCircle
                    ? const BoxDecoration(color: Color(0xFF3E2723), shape: BoxShape.circle)
                    : null,
              ),
            ),
          ),
        ),
        if (showBar)
          Container(
            width: barWidth,
            height: barHeight,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(3),
              // 막대 색(grey.shade300)이 페이지 색(크림, #F4F1E1)과 밝기가
              // 거의 같아서, 그림자만으로는 막대가 페이지 위로 넘어가는
              // 순간 경계가 거의 안 보였습니다(갈색 배경 위에선 또렷했는데
              // 크림색 배경 위에선 거의 묻힘 — "오른쪽이 잘려 보인다"는
              // 제보의 실제 원인). 처음엔 4면 균일 테두리로 고쳤는데, 그러니
              // 오른쪽 아래로 퍼져야 할 방향성 있는 그림자가 테두리에 덮여
              // 밋밋한 스티커처럼 보였습니다("그림자가 가려진 것 같다"는
              // 제보). 테두리 대신 그림자 자체를 더 크고 진하게 키워서,
              // 배경과 무관하게 자연스러운(오른쪽 아래로 비대칭인) 그림자만으로
              // 또렷이 보이도록 합니다.
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 5, spreadRadius: 0.5, offset: const Offset(2, 2)),
              ],
            ),
          ),
      ],
    );
  }
}
