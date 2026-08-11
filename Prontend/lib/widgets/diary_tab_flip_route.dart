import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/news_loading_signal.dart';
import 'diary_page_flipper.dart' show BentLeafPainter, DiaryPageFlipper;
import 'diary_page_frame.dart';
import 'diary_route.dart';

/// 인덱스 탭 전환 전용 라우트. 화면이 옆으로 슬라이드하는 대신, 약 0.5초
/// 동안 여러 장의 속지가 촤라라락 넘어간 뒤 목적지 탭의 메인 페이지가
/// 드러납니다.
///
/// 방향 규칙(다이어리=1, 소식=2, 결산=3, 설정=4번 탭으로 봤을 때):
/// - 번호가 커지는 이동(예: 다이어리→결산)은 앞으로 넘김 — 속지들이
///   책등(왼쪽 바인더 링)을 축으로 들려 올라가 사라집니다.
/// - 번호가 작아지는 이동(예: 설정→소식)은 뒤로 넘김 — 속지들이 책등
///   쪽에서 세워진 채 나타나 오른쪽으로 한 장씩 눕습니다.
class DiaryTabFlipRoute extends PageRouteBuilder<void> {
  DiaryTabFlipRoute({
    required DiaryTab from,
    required DiaryTab to,
    required WidgetBuilder builder,
  }) : super(
          settings: RouteSettings(name: routeNameForDiaryTab(to)),
          transitionDuration: DiaryTabFlipTransition.transitionDuration,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return DiaryTabFlipTransition(
              animation: animation,
              forward: to.index > from.index,
              // 소식 탭으로 이동할 때만, 소식 데이터 로딩이 끝날 때까지
              // 전환 애니메이션이 (로딩 화면 대신) 계속 재생되도록 신호를
              // 넘깁니다. 다른 탭은 null이라 기존과 동일하게 동작합니다.
              holdSignal:
                  to == DiaryTab.news ? NewsLoadingSignal.isLoading : null,
              child: child,
            );
          },
        );
}

/// [DiaryTabFlipRoute]의 실제 전환 화면. 목적지 화면([child]) 위(또는 아래)에
/// 빈 속지 여러 장이 넘어가는 오버레이를 겹쳐 그립니다.
///
/// - 앞으로 넘김: [child](목적지)를 처음부터 바닥에 깔아두고, 그 위에 빈
///   속지들을 평평하게 쌓아뒀다가 한 장씩 들어 올려 없앱니다 — 마지막 장이
///   사라지는 순간 목적지 페이지가 자연스럽게 드러납니다.
/// - 뒤로 넘김: 바닥은 (라우트 스택상 아래에 남아 있는) 이전 화면 그대로
///   두고, 책등에서 속지들이 한 장씩 내려와 쌓입니다. 마지막 장이 다
///   내려앉을 즈음 [child]를 그 위로 페이드인해서, 마지막으로 내려앉은
///   장에 목적지 내용이 스며들 듯 나타나게 합니다.
///
/// 속지 한 장 한 장은 실제 페이지 넘김([DiaryPageFlipper])과 완전히 같은
/// 방식으로 그립니다: 같은 곡면 메시 페인터([BentLeafPainter])에, 같은
/// 곡률/모서리 리드/왼쪽 이동 공식(_buildForwardScene/_buildBackwardScene과
/// 동일)을 넣습니다. 다만 티켓 페이지 대신 빈 종이(페이지 자리에 크림색
/// RRect만 그린 합성 텍스처)를 쓰고, 한 장당 시간이 훨씬 짧고 여러 장이
/// 겹쳐서 넘어갑니다.
class DiaryTabFlipTransition extends StatefulWidget {
  final Animation<double> animation;
  final bool forward;
  final Widget child;

  /// true인 동안은 전환이 끝나도(routeT가 끝에 닿아도) 목적지 화면을
  /// 바로 드러내지 않고, 마지막 속지가 화면을 덮은 정지 화면으로 계속
  /// 대기합니다(소식 탭 로딩 스피너 대신). null이면 기존과 동일하게
  /// 전환이 끝나는 즉시 목적지를 보여줍니다.
  final ValueListenable<bool>? holdSignal;

  const DiaryTabFlipTransition({
    super.key,
    required this.animation,
    required this.forward,
    required this.child,
    this.holdSignal,
  });

  /// 전환 전체(잎이 다 넘어가는 데 걸리는) 시간. 기존 500ms에서 20% 줄임.
  static const Duration transitionDuration = Duration(milliseconds: 400);

  /// 전환 동안 넘어가는 속지 수. 실제 페이지 넘김(한 장 420ms)보다 훨씬
  /// 빠르고 많이 넘어가도록 잡은 값입니다(처음 14장에서 절반으로 조정한
  /// 6장에서, 더 촘촘한 연출을 위해 3장 늘림).
  static const int leafCount = 9;

  /// 속지 한 장이 넘어가는 데 걸리는 시간(전체 전환 시간 1.0 기준).
  /// 전체 0.5초 기준 약 80ms — 실제 페이지 넘김(420ms)의 5배 속도입니다.
  static const double leafSpan = 0.4;

  /// 마지막 속지가 넘어가기를 끝내는 시각(1.0 기준). 남는 끝부분은
  /// 목적지 페이지가 자리를 잡는 여유 구간입니다.
  static const double lastLeafEnd = 0.94;

  /// 마지막 속지가 넘어가기 "시작"하는 시각. 이 시각까지는 마지막 속지가
  /// 평평하게 화면 전체를 덮고 있습니다(p=0으로 고정) — [holdSignal]이
  /// true인 동안(소식 탭 로딩 중) 전환을 이 지점에서 정지시켜, 목적지
  /// 화면이 잠깐도 비치지 않으면서 대기하는 데 씁니다.
  static const double lastLeafStart = lastLeafEnd - leafSpan;

  /// 넘어가는 속지 묶음(leaves)의 실제 렌더링 Rect를 테스트에서 찾기
  /// 위한 key. [DiaryPageFrame]의 실제 프레임 위치와 어긋나지 않는지
  /// 검증하는 diary_tab_flip_frame_alignment_test.dart 전용입니다.
  @visibleForTesting
  static const Key leavesBoxKey = ValueKey('diaryTabFlipLeavesBox');

  @override
  State<DiaryTabFlipTransition> createState() => _DiaryTabFlipTransitionState();
}

class _DiaryTabFlipTransitionState extends State<DiaryTabFlipTransition> {
  /// 뒤로 넘김에서 목적지 화면이 페이드인을 시작/완료하는 시각.
  /// 마지막 속지가 내려앉는 구간의 끝자락과 겹치게 잡아, 내려앉은 빈
  /// 종이에 내용이 스며들 듯 나타납니다.
  static const double _revealStart = 0.84;
  static const double _revealEnd = 0.98;

  bool get _holding => widget.holdSignal?.value ?? false;

  void _onHoldSignalChanged() {
    if (!mounted) return;
    // holdSignal(ValueNotifier)의 notifyListeners()는 동기 호출이라, 이
    // 리스너가 "다른 위젯이 한창 빌드되는 도중"(예: 소식 탭으로 막 전환된
    // 라우트가 처음 지어질 때 NewsScreen.initState가 곧장 로딩 신호를
    // true로 바꾸는 경우) 실행될 수 있습니다. 그 시점에 바로 setState를
    // 부르면 "build 중 setState" 예외가 나므로, 이번 프레임이 끝난 뒤로
    // 미룹니다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
    // addPostFrameCallback은 "다음 프레임이 그려질 때" 실행되도록 예약할
    // 뿐, 그 다음 프레임이 실제로 예약되어 있음을 보장하지는 않습니다.
    // 정적 대기 화면으로 바뀐 뒤로는 이 시점에 다른 애니메이션이 전혀
    // 돌고 있지 않을 수 있어서, 프레임이 그려질 계기가 없으면 콜백이
    // 무기한 미뤄지고 로딩이 끝나도 화면이 영영 드러나지 않는 문제가
    // 있었습니다(실기기에서 재현). 프레임을 명시적으로 예약해서 반드시
    // 다음 프레임에서 실행되게 합니다.
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// 실제 페이지 종이와 같은 색(diary_screen의 _paperColor,
  /// [DiaryPageFrame]의 기본 pageColor와 동일).
  static const Color _leafColor = Color(0xFFF4F1E1);

  /// [DiaryPageFlipper]의 캡처 해상도 상한과 같은 값.
  static const double _rasterMaxDpr = 2.0;

  /// 빈 속지의 합성 텍스처와, [BentLeafPainter]가 재사용하는 셰이더/메시
  /// 버퍼들. [DiaryPageFlipper]가 실제 페이지 스냅샷으로 하는 것과 같은
  /// 구성이며, 프레임 크기가 정해지는 첫 레이아웃에서 한 번만 만듭니다.
  /// (positions/colors 버퍼는 페인터가 매 프레임 덮어쓰지만, 한 프레임
  /// 안에서 잎들이 순서대로 그려지고 Vertices.raw가 값을 복사해 가므로
  /// 여러 장이 공유해도 안전합니다.)
  ui.Image? _leafImage;
  ui.ImageShader? _leafShader;
  Float32List? _meshPositions;
  Float32List? _meshTexCoords;
  Int32List? _meshColors;
  Uint16List? _meshIndices;
  Size? _leafImageSize;

  @override
  void initState() {
    super.initState();
    widget.holdSignal?.addListener(_onHoldSignalChanged);
  }

  @override
  void dispose() {
    widget.holdSignal?.removeListener(_onHoldSignalChanged);
    _leafImage?.dispose();
    super.dispose();
  }

  double _leafProgress(int index, double t) {
    final start = DiaryTabFlipTransition.leafCount == 1
        ? 0.0
        : DiaryTabFlipTransition.lastLeafStart *
            index /
            (DiaryTabFlipTransition.leafCount - 1);
    return ((t - start) / DiaryTabFlipTransition.leafSpan).clamp(0.0, 1.0);
  }

  /// 프레임 크기에 맞는 빈 속지 텍스처(페이지 자리의 크림색 RRect)를
  /// 합성하고 셰이더/메시 버퍼를 준비합니다. toImageSync라 빌드 중에
  /// 동기적으로 만들 수 있고(setState 불필요), 별도 스냅샷 캡처가 필요한
  /// 실제 페이지 넘김과 달리 폴백 프레임 없이 첫 프레임부터 곡면입니다.
  void _ensureLeafImage(BuildContext context, Size frameSize) {
    if (_leafImage != null && _leafImageSize == frameSize) return;
    final dpr =
        math.min(MediaQuery.devicePixelRatioOf(context), _rasterMaxDpr);

    // 실제 페이지 종이와 같은 배치(defaultPageTop/Bottom/Left/Right +
    // widthFactor 중앙 확장)를 프레임 좌표로 계산합니다.
    final pageBoxWidth = frameSize.width -
        DiaryPageFrame.defaultPageLeft -
        DiaryPageFrame.defaultPageRight;
    final pageWidth = pageBoxWidth * DiaryPageFrame.defaultPageWidthFactor;
    final pageLeft = DiaryPageFrame.defaultPageLeft -
        (pageWidth - pageBoxWidth) / 2;
    final pageRect = Rect.fromLTWH(
      pageLeft,
      DiaryPageFrame.defaultPageTop,
      pageWidth,
      frameSize.height -
          DiaryPageFrame.defaultPageTop -
          DiaryPageFrame.defaultPageBottom,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(dpr);
    final rrect = RRect.fromRectAndCorners(
      pageRect,
      topRight: const Radius.circular(15),
      bottomRight: const Radius.circular(15),
    );
    canvas.drawRRect(rrect, Paint()..color = _leafColor);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (frameSize.width * dpr).round(),
      (frameSize.height * dpr).round(),
    );
    picture.dispose();

    _leafImage?.dispose();
    _leafImage = image;
    _leafImageSize = frameSize;

    // 이하 셰이더/버퍼 구성은 DiaryPageFlipper._prepareLeafMesh와 동일.
    _leafShader = ui.ImageShader(
      image,
      TileMode.clamp,
      TileMode.clamp,
      Matrix4.identity().storage,
      filterQuality: FilterQuality.medium,
    );
    const cols = DiaryPageFlipper.bendColumns;
    const rows = DiaryPageFlipper.bendRows;
    const vertexCount = (cols + 1) * (rows + 1);
    _meshPositions = Float32List(vertexCount * 2);
    _meshColors = Int32List(vertexCount);
    final texCoords = Float32List(vertexCount * 2);
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    for (var j = 0; j <= rows; j++) {
      for (var i = 0; i <= cols; i++) {
        final idx = j * (cols + 1) + i;
        texCoords[idx * 2] = (i / cols) * imgW;
        texCoords[idx * 2 + 1] = (j / rows) * imgH;
      }
    }
    _meshTexCoords = texCoords;
    final indices = Uint16List(cols * rows * 6);
    var cursor = 0;
    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < cols; i++) {
        final v00 = j * (cols + 1) + i;
        final v10 = v00 + 1;
        final v01 = v00 + (cols + 1);
        final v11 = v01 + 1;
        indices[cursor++] = v00;
        indices[cursor++] = v10;
        indices[cursor++] = v11;
        indices[cursor++] = v00;
        indices[cursor++] = v11;
        indices[cursor++] = v01;
      }
    }
    _meshIndices = indices;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      child: widget.child,
      builder: (context, child) {
        final t = widget.animation.value;
        // 전환이 끝난 뒤(이 위젯은 라우트가 살아있는 동안 트리에 남습니다)
        // 에는 목적지 화면만 그대로 보여줍니다(바인더 링도 정상적으로 다시
        // 보입니다).
        //
        // 앞으로 넘김(forward)은 마지막 속지가 lastLeafEnd 시점에 완전히
        // 사라지는데(_leafProgress가 1.0이 되면 _buildLeaves에서 제외),
        // 링을 가리는 클립은 t>=1.0까지 계속 적용돼서 "속지도 없고 실제
        // 링도 가려진" 빈 구간(lastLeafEnd~1.0, 약 30ms)이 생겨 그 틈으로
        // 배경이 잠깐 비쳐 보이는 깜빡임이 있었습니다. 뒤로 넘김은 마지막
        // 속지가 끝까지 평평하게 남아 있어(p<=0일 때만 제외) 이 틈이 없어
        // 괜찮습니다. 그래서 forward만 lastLeafEnd 시점부터 곧장 목적지
        // 화면(실제 링 포함)을 보여주도록 임계값을 다르게 둡니다.
        final doneThreshold =
            widget.forward ? DiaryTabFlipTransition.lastLeafEnd : 1.0;
        if (t < doneThreshold) return _buildScene(context, t, child!);
        if (!_holding) return child!;

        // 목적지(소식 탭) 로딩이 아직 안 끝났습니다: 정상 전환은 끝났지만
        // 목적지를 드러내지 않고, lastLeafStart 시점(마지막 속지가 아직
        // 시작 전이라 화면 전체를 평평하게 덮고 있는 상태)에서 정지한
        // 정적인 화면으로 대기합니다 — 로딩 스피너 대신 "전환이 아직
        // 끝나지 않은 것처럼" 자연스럽게 이어 보이게 하는 용도입니다.
        // (반복 재생 루프로 구현했을 때는 매 프레임 복잡한 곡면 메시를
        // 다시 그리다가 정점 부근에서 렌더링이 꼬여 잎과 바인더 링이
        // 동시에 비치는 등 실제 기기에서 화면이 깨지는 문제가 있었습니다
        // — 정적 프레임 하나만 그리는 지금 방식은 그 문제 자체가 생길
        // 여지가 없습니다.)
        return _buildScene(
          context,
          DiaryTabFlipTransition.lastLeafStart,
          child!,
          forceCovered: true,
        );
      },
    );
  }

  /// 넘어가는 속지들과 목적지/이전 화면([child])을 함께 배치합니다.
  ///
  /// 전환 중에는 바인더 링(은색 막대 포함)을 아예 그리지 않습니다 —
  /// 자연스러운 느낌을 위해, 넘어가는 속지들만 보이고 링/막대는 전환이
  /// 끝난 뒤 목적지 화면이 완전히 자리 잡을 때만 나타납니다. [child]는
  /// 화면 전체 크기를 그대로 유지해야 하므로(AspectRatio 안에 새로 넣으면
  /// 이중으로 축소됨) [ClipRect]로 링이 있는 자리(왼쪽 여백)만 화면 전체
  /// 좌표 기준으로 가려서, 목적지 화면 자신의 실제 링이 비쳐 보이지
  /// 않게 합니다.
  Widget _buildScene(
    BuildContext context,
    double t,
    Widget child, {
    bool forceCovered = false,
  }) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final availableHeight = constraints.maxHeight;
          const aspectRatio = DiaryPageFrame.diaryAspectRatio;

          // AspectRatio 위젯과 완전히 같은 규칙: 화면비가 더 넓으면
          // 높이를 꽉 채우고, 더 좁거나 같으면 폭을 꽉 채웁니다.
          double frameWidth;
          double frameHeight;
          if (availableWidth / availableHeight > aspectRatio) {
            frameHeight = availableHeight;
            frameWidth = frameHeight * aspectRatio;
          } else {
            frameWidth = availableWidth;
            frameHeight = frameWidth / aspectRatio;
          }
          final marginEachSide =
              math.max(0.0, (availableWidth - frameWidth) / 2);
          // DiaryPageFrame.build()는 AspectRatio를 Center로 감싸서 가로뿐
          // 아니라 세로도 중앙 정렬합니다(diaryAspectRatio가 화면비보다
          // 좁은 대부분의 폰에서는 frameHeight < availableHeight라 위아래
          // 여백이 생김). 여기서 top을 0으로 고정하면 그 여백만큼 실제
          // 다이어리 페이지 위치보다 위로 밀려 보이므로, 같은 공식으로
          // 세로 마진도 계산해 맞춰야 합니다 — 기기별 화면비 차이로 이
          // 여백 크기가 달라, "몇몇 기기에서만" 어긋나 보이던 원인입니다.
          final marginTop =
              math.max(0.0, (availableHeight - frameHeight) / 2);

          final metrics = DiaryPageFrame.computeRingMetrics(
            frameWidth: frameWidth,
            frameHeight: frameHeight,
          );
          _ensureLeafImage(context, Size(frameWidth, frameHeight));

          final leaves = Positioned(
            left: marginEachSide,
            top: marginTop,
            width: frameWidth,
            height: frameHeight,
            child: IgnorePointer(
              key: DiaryTabFlipTransition.leavesBoxKey,
              child: Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: _buildLeaves(t, metrics),
              ),
            ),
          );

          // 링(원+막대)을 가리는 x좌표(SafeArea 기준 = child와 같은
          // 좌표계): binderLeft(링의 왼쪽 끝)가 아니라 막대의 "오른쪽"
          // 끝(pivotX + barWidth/2, 막대 중심이 pivotX라 거기서 반 폭
          // 만큼 더)까지 가려야 합니다. binderLeft는 페이지 확장 폭 때문에
          // 거의 항상 음수라, 그 값을 그대로 쓰면(0으로 clamp돼) 사실상
          // 아무것도 안 가려지는 문제가 있었습니다 — 실제 시뮬레이터에서
          // 확인 후 발견.
          final hideRingClip = _LeftEdgeClipper(
            marginEachSide + metrics.pivotX + metrics.barWidth / 2,
          );

          if (widget.forward || forceCovered) {
            // 목적지(child)가 바닥, 속지들이 그 위. 속지가 다 넘어가면
            // 목적지가 드러납니다. child 자신의 실제 링은 속지가 다
            // 사라지기 전까지 clip으로 가려둡니다.
            //
            // forceCovered(로딩 대기 정지 화면)는 원래 뒤로 넘김이었어도
            // 이 분기를 씁니다 — 뒤로 넘김의 정상 분기(아래)는 reveal
            // 페이드로 child가 미리 살짝 비치기 시작하는데, 대기 중엔
            // 항상 완전히 가려둬야 하기 때문입니다.
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                ClipRect(clipper: hideRingClip, child: child),
                leaves,
              ],
            );
          }

          // 뒤로 넘김: 바닥은 이전 화면(라우트 스택 아래, child가 투명한
          // 동안 비쳐 보임), 속지들이 쌓인 뒤 목적지가 맨 위로 페이드인.
          // child를 조건부로 뺐다 넣으면 화면 State가 통째로 다시 만들어
          // 지므로(초기 로딩 재실행), 투명해도 항상 트리에 둡니다.
          final reveal =
              ((t - _revealStart) / (_revealEnd - _revealStart)).clamp(0.0, 1.0);
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              leaves,
              ClipRect(
                clipper: hideRingClip,
                child: Opacity(opacity: reveal, child: child),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 넘어가는 속지들만 만듭니다(바인더 링은 포함하지 않음 — 전환 중엔
  /// 숨깁니다).
  List<Widget> _buildLeaves(double t, ({
    double barWidth,
    double barHeight,
    double circleShiftX,
    double binderLeft,
    double pivotX,
    double pageWidth,
  }) metrics) {
    // 실제 페이지 넘김(_buildForwardScene)과 같은 기준:
    // 잎이 다 넘어갈 때 은색 막대 절반만큼 왼쪽으로 이동.
    final maxTranslateX = metrics.barWidth * 0.5;

    final leaves = <Widget>[];
    for (var i = 0; i < DiaryTabFlipTransition.leafCount; i++) {
      final p = _leafProgress(i, t);
      // 실제 페이지 넘김과 같은 공식으로 각도/곡률/모서리 리드/이동을
      // 계산합니다. 앞으로 넘김의 p는 DiaryPageFlipper
      // _buildForwardScene의 bendPhase(0~1, 잎이 보이는 구간)와 같고,
      // 뒤로 넘김의 p는 _buildBackwardScene의 progress와 같습니다.
      final double angle;
      final double bend;
      final double cornerLead;
      final double translateX;
      if (widget.forward) {
        // 평평(0)하게 깔려 있다가 책등에 세워지며(π/2) 사라짐.
        if (p >= 1.0) continue;
        angle = p * math.pi / 2;
        bend = DiaryPageFlipper.maxBend * math.sin(math.pi * p);
        cornerLead = DiaryPageFlipper.maxCornerLead * (1.0 - p);
        translateX = -maxTranslateX * ((p - 0.5) / 0.5).clamp(0.0, 1.0);
      } else {
        // 책등에 세워진 채(π/2) 숨어 있다가 내려와(0) 쌓임.
        if (p <= 0.0) continue;
        angle = (1.0 - p) * math.pi / 2;
        bend = DiaryPageFlipper.maxBend * math.sin(math.pi * p);
        cornerLead = DiaryPageFlipper.maxCornerLead * p;
        translateX = -maxTranslateX * (1.0 - 2.0 * p).clamp(0.0, 1.0);
      }
      leaves.add(_buildLeaf(
        angle: angle,
        bend: bend,
        cornerLead: cornerLead,
        translateX: translateX,
        pivotX: metrics.pivotX,
      ));
    }

    // z순서: 앞으로 넘김은 먼저 넘어가는(위에 놓인) 장이 맨 위, 뒤로
    // 넘김은 나중에 내려앉는 장이 맨 위(쌓이는 순서).
    return widget.forward ? leaves.reversed.toList(growable: false) : leaves;
  }

  /// 속지 한 장. 실제 페이지 넘김과 같은 곡면 메시([BentLeafPainter])로
  /// 그립니다. 텍스처는 티켓 페이지 스냅샷 대신 빈 종이 합성 이미지
  /// ([_ensureLeafImage])입니다.
  Widget _buildLeaf({
    required double angle,
    required double bend,
    required double cornerLead,
    required double translateX,
    required double pivotX,
  }) {
    final image = _leafImage;
    final shader = _leafShader;
    if (image == null || shader == null) {
      // toImageSync 실패 등 예외 상황 폴백: 실제 페이지 넘김의 캡처 전
      // 폴백과 같은 단순 평면 회전.
      return Positioned.fill(
        child: Transform.translate(
          offset: Offset(translateX, 0),
          child: Transform(
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001)
              ..rotateY(angle),
            alignment: Alignment.centerLeft,
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: DiaryPageFrame.defaultPageTop,
                  bottom: DiaryPageFrame.defaultPageBottom,
                  left: DiaryPageFrame.defaultPageLeft,
                  right: DiaryPageFrame.defaultPageRight,
                  child: FractionallySizedBox(
                    widthFactor: DiaryPageFrame.defaultPageWidthFactor,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _leafColor,
                        borderRadius: DiaryPageFrame.defaultPageBorderRadius,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned.fill(
      child: CustomPaint(
        painter: BentLeafPainter(
          image: image,
          shader: shader,
          positions: _meshPositions!,
          texCoords: _meshTexCoords!,
          colors: _meshColors!,
          indices: _meshIndices!,
          angle: angle,
          bend: bend,
          cornerLead: cornerLead,
          pivotX: pivotX,
          translateX: translateX,
          columns: DiaryPageFlipper.bendColumns,
          rows: DiaryPageFlipper.bendRows,
        ),
      ),
    );
  }
}

/// [x] 왼쪽을 전부 잘라내는(투명하게 만드는) 클리퍼. 전환 중 목적지/이전
/// 화면([child])에서 바인더 링이 그려지는 왼쪽 여백만 가리는 데 씁니다.
/// 화면 크기 자체([Size] getClip의 인자)는 참고하지 않고 절대 x좌표
/// [x] 하나만으로 잘라내므로, [child]가 자기 크기 그대로 레이아웃된
/// 상태를 유지하면서 페인트만 가릴 수 있습니다.
class _LeftEdgeClipper extends CustomClipper<Rect> {
  final double x;
  const _LeftEdgeClipper(this.x);

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(x.clamp(0.0, size.width), 0, size.width, size.height);

  @override
  bool shouldReclip(covariant _LeftEdgeClipper oldClipper) => oldClipper.x != x;
}
