import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'diary_page_frame.dart' show DiaryPageFrame;

/// 페이지 넘김 방향(한 번의 드래그 제스처 동안 유지).
enum _FlipDirection { forward, backward }

/// 다이어리 페이지를 좌우 스와이프로 넘기는 위젯.
///
/// - 왼쪽으로 스와이프: 현재 페이지([frontPage])가 책등(왼쪽 바인더 링)을
///   축으로 들려 올라가며 다음 페이지([backPage])가 드러납니다.
/// - 오른쪽으로 스와이프: 이전 페이지([prevPage])가 책등 너머에서 세워진
///   채로 나타나 현재 페이지 위로 눕습니다(앞으로 넘김을 시간 역재생한
///   것과 같은 움직임).
///
/// 넘어가는 페이지 잎은 종이처럼 살짝 휘어져 보입니다. 페이지 내용에는
/// 티켓별 GlobalKey가 들어 있어 위젯을 조각내 여러 번 마운트할 수 없으므로,
/// 드래그가 시작되는 순간 해당 페이지를 이미지로 캡처해 두고
/// [BentLeafPainter]가 세로 조각들로 나눠 조각마다 조금씩 다른 각도로
/// 그려 곡면을 만듭니다. 회전축은 잎의 왼쪽 모서리(바인더 링 라인)에
/// 고정되어, 페이지가 링에 꿰인 채 링을 지나 넘어가는 것처럼 보입니다.
/// (링 자체는 DiaryPageFrame이 이 위젯보다 위 레이어에 그립니다.)
class DiaryPageFlipper extends StatefulWidget {
  final Widget frontPage; // 현재 페이지
  final Widget backPage; // 다음 페이지 뒷면

  /// 뒤로 넘길 때 왼쪽에서 돌아오는 이전 페이지.
  /// null이면(첫 페이지) 뒤로 넘김이 비활성화됩니다.
  final Widget? prevPage;
  final VoidCallback? onFlipForward; // 다음 페이지로 넘어갈 때 콜백
  final VoidCallback? onFlipBackward; // 이전 페이지로 돌아갈 때 콜백
  final bool flipUpward; // true: 위로 넘김, false: 아래로 넘김
  /// 플립 애니메이션 진행도(0.0: 정지 ~ 1.0: 애니메이션 끝)를 알려주는
  /// notifier. 방향과 무관하게 지금 진행 중인 컨트롤러의 값을 그대로
  /// 흘려보내므로, 바인더 링처럼 이 속도에 맞춰 함께 움직이는 효과를
  /// 만드는 데 씁니다.
  final ValueNotifier<double>? flipProgressNotifier;

  /// 잎이 회전하는 축(책등)의 x좌표. 잎 박스의 왼쪽 모서리가 곧 책등이면
  /// 0, 잎 박스가 페이지보다 넓어서(예: 인덱스 탭 포함을 위해 프레임 전체)
  /// 책등이 안쪽에 있으면 그 x좌표를 넘깁니다. 이보다 왼쪽 영역은 회전하지
  /// 않고 제자리에 남습니다(페이지 왼쪽 여백은 투명이라 보이지 않음).
  final double pivotX;

  /// 잎 박스 오른쪽에서 이 폭만큼은 스와이프 제스처를 받지 않습니다. 잎
  /// 박스가 프레임 전체를 차지할 때(우측 인덱스 탭 포함), 그 자리엔 보통
  /// 프레임에 고정된 다른 탭(예: 소식/결산/설정)이 함께 있는데, 여기까지
  /// 제스처가 가로채면 그 탭들이 눌리지 않기 때문입니다.
  final double dragExclusionRight;

  /// 페이지와 함께 넘어가는 인덱스 탭(이미 `Positioned`로 위치가 잡혀
  /// 있어야 함). [frontPage]/[backPage]/[prevPage] 안에 직접 넣지 않고
  /// 여기로 따로 받습니다 — 탭이 책등(회전축)에서 아주 먼 자리에 있다
  /// 보니, 페이지 전체를 3D로 휘게 만드는 메시 계산에 같이 포함되면
  /// 조각나듯 깨져 보였습니다(회전축에서 먼 점일수록 행별 회전각 차이가
  /// 커서 뒤틀림이 심해짐). 바닥에 깔린("정지") 페이지 위에는 그대로,
  /// 회전 중인 잎 위에는 같은 각도로 단순 평면 회전만 적용해서 따로
  /// 그립니다.
  final Widget? activeTab;

  const DiaryPageFlipper({
    super.key,
    required this.frontPage,
    required this.backPage,
    this.prevPage,
    this.onFlipForward,
    this.onFlipBackward,
    this.flipUpward = true,
    this.flipProgressNotifier,
    this.pivotX = 0.0,
    this.dragExclusionRight = 0.0,
    this.activeTab,
  });

  /// 곡면 잎 렌더링([BentLeafPainter])의 공용 파라미터들. 인덱스 탭 전환
  /// ([DiaryTabFlipRoute])이 "실제 페이지 넘김과 똑같은 이미지"로 속지를
  /// 그리기 위해 같은 값을 공유합니다.
  ///
  /// 곡면을 근사하는 메시의 가로 분할(열)/세로 분할(행) 수.
  static const int bendColumns = 14;
  static const int bendRows = 10;

  /// 최대 곡률(잎 끝과 뿌리의 회전각 차이 비율). 0이면 평면.
  static const double maxBend = 0.9;

  /// 오른쪽 아래 모서리가 먼저 들리는(또는 마지막까지 남는) 정도.
  static const double maxCornerLead = 0.15;

  @override
  State<DiaryPageFlipper> createState() => _DiaryPageFlipperState();
}

class _DiaryPageFlipperState extends State<DiaryPageFlipper>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late AnimationController _backController;
  bool _isAutoFlipping = false;

  /// 이번 드래그 제스처가 어느 방향 넘김인지. 제스처가 끝나면 초기화됩니다.
  _FlipDirection? _dragDirection;

  /// 정지 상태에서 캡처용으로 쓰는 페이지 경계 키.
  final GlobalKey _frontCaptureKey = GlobalKey();
  final GlobalKey _prevCaptureKey = GlobalKey();

  /// 곡면 렌더링에 쓰는 넘어가는 페이지의 스냅샷.
  /// 캡처 전(드래그 첫 프레임 등)에는 평면 회전으로 폴백합니다.
  ui.Image? _leafImage;
  bool _capturePending = false;

  /// 스냅샷으로 만든 셰이더와 메시 버퍼. 프레임마다 새로 만들면(특히
  /// ImageShader) 시뮬레이터에서 눈에 띄게 버벅여서, 캡처 시 한 번만 만들어
  /// 두고 매 프레임 재사용합니다. 위치/음영 버퍼는 페인터가 덮어씁니다.
  ui.ImageShader? _leafShader;
  Float32List? _meshPositions;
  Float32List? _meshTexCoords;
  Int32List? _meshColors;
  Uint16List? _meshIndices;

  /// 캡처 해상도 상한. 페이지가 움직이며 휘어지는 동안에만 보이는
  /// 스냅샷이라 기기 배율(3x) 그대로 뜨면 toImage가 드래그 시작 프레임을
  /// 멈칫하게 할 만큼 무겁습니다. 2x면 충분히 선명합니다.
  static const double _captureMaxDpr = 2.0;

  /// 곡면 메시/곡률 파라미터. 실제 값은 [DiaryPageFlipper]의 공개 상수를
  /// 그대로 씁니다(인덱스 탭 전환과 공유 — 해당 상수 문서 참고).
  static const int _bendColumns = DiaryPageFlipper.bendColumns;
  static const int _bendRows = DiaryPageFlipper.bendRows;
  static const double _maxBend = DiaryPageFlipper.maxBend;

  /// 아래쪽 행의 회전각이 위쪽 행보다 이 비율의 절반씩 더/덜 커집니다.
  static const double _maxCornerLead = DiaryPageFlipper.maxCornerLead;

  /// 페이지가 넘어가는 동안 잎이 왼쪽으로 추가로 이동하는 최대 거리(px).
  /// 고정 픽셀값이 아니라 은색 막대 폭을 기준으로 정의합니다.
  /// [barWidthFraction]이 0.5면 막대 폭의 절반(막대 중심이 pivotX와 같은
  /// 위치라, 그 절반만큼 이동하면 막대 왼쪽 끝과 만남) — 뒤로 넘길 때
  /// 씁니다. 1.0이면 막대 폭 전체만큼 이동합니다 — 앞으로 넘길 때 씁니다.
  double _maxLeafTranslateX(double frameWidth, double frameHeight, {required double barWidthFraction}) {
    final metrics = DiaryPageFrame.computeRingMetrics(frameWidth: frameWidth, frameHeight: frameHeight);
    return metrics.barWidth * barWidthFraction;
  }

  bool get _canFlipForward => widget.onFlipForward != null;
  bool get _canFlipBackward =>
      widget.onFlipBackward != null && widget.prevPage != null;

  @override
  void initState() {
    super.initState();
    // 앞으로 넘김 진행도 (0.0: 정지 ~ 1.0: 다음 페이지). 기존(350ms)보다
    // 20% 느리게.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );

    // 뒤로 넘김 진행도 (0.0: 정지 ~ 1.0: 이전 페이지로 복귀 완료)
    _backController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );

    _controller.addListener(_syncFlipProgress);
    _backController.addListener(_syncFlipProgress);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        _disposeLeafImage();
        widget.flipProgressNotifier?.value = 0.0;
      }
    });
    _backController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        _disposeLeafImage();
        widget.flipProgressNotifier?.value = 0.0;
      }
    });
  }

  /// 지금 진행 중인 쪽(앞/뒤 중 값이 0이 아닌 쪽)의 진행도를 흘려보냅니다.
  /// 앞으로 넘기기는 양수(0~1), 뒤로 넘기기는 음수(0~-1)로 부호를 달리해서,
  /// 구독하는 쪽([DiaryPageFrame])이 방향을 구분해 반대로 반응할 수
  /// 있게 합니다. 정지 상태(둘 다 0)는 앞으로 넘기기 쪽(0, 양수 분기)과
  /// 같은 값이라 항상 "보이는" 쪽으로 자연스럽게 귀결됩니다.
  void _syncFlipProgress() {
    final notifier = widget.flipProgressNotifier;
    if (notifier == null) return;
    final progress = _controller.value != 0.0
        ? _controller.value
        : -_backController.value;
    if (notifier.value != progress) {
      notifier.value = progress;
    }
  }

  void _disposeLeafImage() {
    _leafImage?.dispose();
    _leafImage = null;
    _leafShader = null;
    _meshPositions = null;
    _meshTexCoords = null;
    _meshColors = null;
    _meshIndices = null;
  }

  /// 캡처 직후 한 번만: 셰이더와, 프레임 간 변하지 않는 텍스처 좌표/삼각형
  /// 인덱스를 만들어 둡니다. 위치/음영 버퍼도 여기서 할당만 해 둡니다.
  void _prepareLeafMesh(ui.Image image) {
    _leafShader = ui.ImageShader(
      image,
      TileMode.clamp,
      TileMode.clamp,
      Matrix4.identity().storage,
      filterQuality: FilterQuality.medium,
    );

    const cols = _bendColumns;
    const rows = _bendRows;
    final vertexCount = (cols + 1) * (rows + 1);
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

  /// 넘어갈 페이지를 이미지로 캡처합니다. 정지 상태에서 해당 페이지가
  /// (가려져 있더라도) 실제로 그려져 있어야 성공합니다. 실패하면 이번
  /// 제스처는 평면 회전으로 폴백합니다.
  Future<void> _captureLeaf(_FlipDirection direction) async {
    if (_capturePending || _leafImage != null) return;
    _capturePending = true;
    try {
      final key = direction == _FlipDirection.forward
          ? _frontCaptureKey
          : _prevCaptureKey;
      final boundary =
          key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final dpr = math.min(
        MediaQuery.devicePixelRatioOf(context),
        _captureMaxDpr,
      );
      final image = await boundary.toImage(pixelRatio: dpr);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _leafImage = image;
        _prepareLeafMesh(image);
      });
    } catch (_) {
      // 캡처 실패(아직 안 그려짐 등) 시 평면 회전 폴백.
    } finally {
      _capturePending = false;
    }
  }

  void _handleForwardFlip() {
    if (_isAutoFlipping) return;
    _isAutoFlipping = true;

    _controller.forward().then((_) {
      if (!mounted) return;
      widget.onFlipForward?.call();
      // onFlipForward가 상위(diary_screen.dart)의 쿨다운(_flipCooldown)에
      // 걸려 _currentPageIndex를 바꾸지 않고 조용히 반환하는 경우가 있는데,
      // 그러면 이 위젯의 key(ValueKey('flipper_$_currentPageIndex'))도
      // 그대로라 새 State가 생기지 않습니다. 그 상태에서 _isAutoFlipping을
      // 리셋하지 않으면 이후 모든 드래그 제스처가 계속 무시돼(위 가드들이
      // 전부 이 값을 확인함) 화면이 넘김에 반응 없는(멈춘) 것처럼 보였습니다.
      // 페이지 전환 성공 여부와 무관하게 항상 정지 상태로 되돌립니다.
      // value를 0으로 되돌리면 completed -> dismissed 상태 전환이 일어나
      // 기존 addStatusListener가 _disposeLeafImage/flipProgressNotifier 정리를
      // 알아서 처리합니다(_controller.addListener(_syncFlipProgress)도
      // 마찬가지로 값이 바뀌면 자동으로 다시 불립니다).
      _isAutoFlipping = false;
      _controller.value = 0.0;
    });
  }

  void _handleBackwardFlip() {
    if (_isAutoFlipping) return;
    _isAutoFlipping = true;

    _backController.forward().then((_) {
      if (!mounted) return;
      widget.onFlipBackward?.call();
      // 위 _handleForwardFlip과 동일한 이유로, 쿨다운에 막혀 페이지가 안
      // 바뀌어도 제스처가 영구히 멈추지 않도록 항상 정지 상태로 되돌립니다.
      _isAutoFlipping = false;
      _backController.value = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 시각적 내용(회전/곡률 등)은 항상 프레임 전체를 채워야 하지만, 스와이프
    // 제스처는 [dragExclusionRight]만큼 오른쪽을 제외한 영역에서만 받습니다.
    // 그 자리엔 DiaryPageFrame에 고정된 탭(소식/결산/설정)이 있는데, 예전엔
    // 이 위젯이 프레임 전체를 opaque GestureDetector로 덮어서 그 탭들의
    // 탭(누름) 이벤트를 가로채 눌리지 않는 문제가 있었습니다.
    return LayoutBuilder(
      builder: (context, constraints) {
        final frameWidth = constraints.maxWidth;
        final frameHeight = constraints.maxHeight;
        return Stack(
          fit: StackFit.expand,
          // 기본값(Clip.hardEdge)이면 이 프레임 크기 경계에서 잘립니다 —
          // "다이어리" 활성 탭이 여백 밖으로 튀어나가야 하는데(DiaryPageFrame.
          // buildScaledSideTab 참고) 그 부분이 잘려 반쪽만 보이는 문제가
          // 있었습니다. 이 아래 중첩된 Stack들(_buildIdleScene/
          // _buildForwardScene/_buildBackwardScene/_buildLeaf)도 전부
          // 같은 이유로 Clip.none이 필요합니다.
          clipBehavior: Clip.none,
          children: [
            SizedBox.expand(
              child: AnimatedBuilder(
                animation: Listenable.merge([_controller, _backController]),
                builder: (context, child) {
                  final forward = _controller.value;
                  final backward = _backController.value;

                  if (backward > 0 && widget.prevPage != null) {
                    return _buildBackwardScene(backward, frameWidth, frameHeight);
                  }
                  if (forward > 0) {
                    return _buildForwardScene(forward, frameWidth, frameHeight);
                  }
                  return _buildIdleScene(frameWidth, frameHeight);
                },
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              right: widget.dragExclusionRight,
              child: _buildDragDetector(context),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDragDetector(BuildContext context) {
    return GestureDetector(
      // 이 감지기는 시각적 콘텐츠를 감싸지 않고 별도의 형제 레이어로 위에
      // 얹혀 있습니다(dragExclusionRight로 오른쪽 탭 자리만 제외하기
      // 위해서). opaque로 두면 Stack이 이 레이어에서 히트테스트를
      // 멈춰버려서, 뒤에 있는 티켓 카드/티켓 추가 버튼 등 콘텐츠가 아예
      // 눌리지 않게 됩니다. translucent는 이 레이어도 제스처를 받으면서
      // (드래그 인식은 그대로 동작) 뒤쪽 위젯까지 히트테스트를 계속
      // 진행시켜, 움직임 없는 탭은 뒤쪽 위젯이 정상적으로 받습니다.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (details) {
        if (_isAutoFlipping) return;
        final delta =
            (details.primaryDelta ?? 0.0) / MediaQuery.of(context).size.width;
        if (delta == 0.0) return;

        // 진행 중인 방향이 없거나 진행도가 원점(0)이면, 이번 델타의 방향으로
        // 넘김 방향을 (다시) 정합니다. 손가락 미세 떨림으로 반대 방향이 먼저
        // 잡혀도 원점에서는 곧바로 의도한 방향으로 바로잡힙니다.
        final activeValue = switch (_dragDirection) {
          _FlipDirection.forward => _controller.value,
          _FlipDirection.backward => _backController.value,
          null => 0.0,
        };
        if (_dragDirection == null || activeValue == 0.0) {
          final previous = _dragDirection;
          if (delta < 0 && _canFlipForward) {
            _dragDirection = _FlipDirection.forward;
          } else if (delta > 0 && _canFlipBackward) {
            _dragDirection = _FlipDirection.backward;
          } else {
            return;
          }
          // 방향이 바뀌었으면 이전 방향 페이지의 스냅샷은 버립니다.
          if (previous != null && previous != _dragDirection) {
            _disposeLeafImage();
          }
          // 곡면 렌더링용 스냅샷. 아직 정지 화면(캡처 원본이 그려진 상태)
          // 이므로 이 시점에 찍어야 합니다.
          unawaited(_captureLeaf(_dragDirection!));
        }

        if (_dragDirection == _FlipDirection.forward) {
          // 왼쪽으로 스와이프 (음수) -> value 증가 (0.0 -> 1.0)
          _controller.value -= delta;

          // 90도(0.5)를 넘어가면 자동으로 페이지를 넘김
          if (_controller.value > 0.5) {
            _handleForwardFlip();
          }
        } else {
          // 오른쪽으로 스와이프 (양수) -> value 증가 (0.0 -> 1.0)
          _backController.value += delta;

          // 절반(0.5)을 넘어가면 자동으로 이전 페이지로 복귀
          if (_backController.value > 0.5) {
            _handleBackwardFlip();
          }
        }
      },
      onHorizontalDragEnd: (details) {
        final direction = _dragDirection;
        _dragDirection = null;
        if (_isAutoFlipping) return;

        final velocity = details.primaryVelocity ?? 0.0;

        if (direction == _FlipDirection.backward) {
          // 오른쪽으로 빠르게 스와이프(velocity > 0) 혹은 이미 절반 이상 넘긴 경우
          if (_backController.value > 0.5 || velocity > 300) {
            _handleBackwardFlip();
          } else {
            // 제자리 복귀
            _backController.animateTo(0.0);
          }
          return;
        }

        if (!_canFlipForward) return;

        // 왼쪽으로 빠르게 스와이프(velocity < 0) 혹은 이미 절반 이상 넘긴 경우
        if (_controller.value > 0.5 || velocity < -300) {
          _handleForwardFlip();
        } else {
          // 제자리 복귀
          _controller.animateTo(0.0);
        }
      },
    );
  }

  /// 정지 상태. 현재 페이지가 보이고, 그 아래에 이전 페이지를 (가려진 채로)
  /// 함께 그려 둡니다 — 뒤로 넘김이 시작되는 순간 스냅샷을 찍을 원본입니다.
  Widget _buildIdleScene(double frameWidth, double frameHeight) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        if (widget.prevPage != null)
          Positioned.fill(
            child: RepaintBoundary(
              key: _prevCaptureKey,
              child: widget.prevPage!,
            ),
          ),
        _buildStaticPageShadow(),
        Positioned.fill(
          child: RepaintBoundary(
            key: _frontCaptureKey,
            child: widget.frontPage,
          ),
        ),
        if (widget.activeTab != null) widget.activeTab!,
      ],
    );
  }

  /// 앞으로 넘김: 다음 페이지가 바닥에 깔리고, 현재 페이지 잎이 책등을
  /// 축으로 휘어지며 넘어갑니다. 90도(0.5)를 넘어가면 잎을 숨깁니다.
  Widget _buildForwardScene(double progress, double frameWidth, double frameHeight) {
    final angle = progress * math.pi;
    // 곡률은 들리기 시작할 때 0에서 커졌다가 수직(90도)에 가까워지면
    // 다시 펴집니다(사라지기 직전 형태가 튀지 않도록).
    final bendPhase = (progress / 0.5).clamp(0.0, 1.0);
    final bend = _maxBend * math.sin(math.pi * bendPhase);
    // 넘기기 시작할 땐 오른쪽 아래 모서리가 먼저 들리고(리드 최대),
    // 수직에 가까워질수록 페이지 전체가 고르게 섭니다(리드 0).
    final cornerLead = _maxCornerLead * (1.0 - bendPhase);
    // 넘어가는 동안 잎이 왼쪽으로 이동해서, 잎이 사라지는 시점
    // (progress=0.5, bendPhase=1)에 딱 바인더 링 은색 막대의 왼쪽 끝에
    // 도달합니다(진행도 끝에서 최대, 막대 폭의 절반만큼 이동). 다만 이동
    // 자체는 bendPhase가 절반(0.5)을 넘어서야(=페이지가 절반 이상
    // 넘어갔을 때) 시작합니다 — 그 전까지는 제자리에서 휘어지기만 합니다.
    final maxTranslateX = _maxLeafTranslateX(frameWidth, frameHeight, barWidthFraction: 0.5);
    final translatePhase = ((bendPhase - 0.5) / 0.5).clamp(0.0, 1.0);
    final translateX = -maxTranslateX * translatePhase;

    // ClipRect로 감싸지 않습니다 — 넘어가는 잎이 페이지 영역 밖으로
    // 자연스럽게 튀어나와 보여야 실제 종이를 넘기는 느낌이 납니다.
    // (바깥 DiaryPageFrame의 Stack도 Clip.none이라 그대로 그려집니다.)
    // 이 Stack 자신도 명시적으로 Clip.none이어야 합니다 — 기본값
    // (Clip.hardEdge)이면 이 위젯이 직접 이 프레임 크기 경계에서 잘라내,
    // 위 주석의 의도(잎이 잘리지 않고 튀어나옴)와 별개로 activeTab이
    // 여백 밖으로 튀어나가는 부분이 잘렸습니다.
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        _buildStaticPageShadow(),
        Positioned.fill(child: RepaintBoundary(child: widget.backPage)),
        // backPage(바닥에 깔린 다음 페이지)도 자기 탭을 갖고 있는 것처럼,
        // 정지 상태와 동일하게 그대로(회전 없이) 얹어둡니다.
        if (widget.activeTab != null) widget.activeTab!,
        if (progress <= 0.5)
          _buildLeaf(
            angle: angle,
            bend: bend,
            cornerLead: cornerLead,
            liveFallback: widget.frontPage,
            translateX: translateX,
            tab: widget.activeTab,
          ),
      ],
    );
  }

  /// 뒤로 넘김: 현재 페이지가 바닥에 깔리고, 이전 페이지 잎이 책등에
  /// 세워진 상태(90도)에서 휘어지며 현재 페이지 위로 눕습니다(0도).
  Widget _buildBackwardScene(double progress, double frameWidth, double frameHeight) {
    final angle = (1.0 - progress) * math.pi / 2;
    // 시작(세워진 상태)엔 곧게, 눕는 도중 가장 휘고, 다 누우면 펴집니다.
    final bend = _maxBend * math.sin(math.pi * progress.clamp(0.0, 1.0));
    // 고르게 세워진 상태에서 내려오다가, 바닥에 닿기 직전엔 오른쪽 아래
    // 모서리가 마지막까지 들려 있다가 내려앉습니다(넘길 때의 역재생).
    final cornerLead = _maxCornerLead * progress.clamp(0.0, 1.0);
    // 앞으로 넘길 때(_buildForwardScene)의 translateX를 정확히 시간
    // 역재생한 값입니다: 거기서는 bendPhase(0~1)가 0.5를 넘어야 이동을
    // 시작해 1에서 최대(은색 막대 왼쪽 끝)에 도달합니다. 뒤로 넘기기의
    // progress는 앞으로 넘기기의 (1 - bendPhase)에 해당하므로, 시작
    // (progress=0, 세워진 상태)엔 이미 최대로 이동해 있다가, 절반
    // (progress=0.5)에서 0으로 돌아온 뒤 나머지 구간은 0에 머뭅니다 —
    // 애니메이션이 끝나는 지점이 정지 상태와 똑같이(이동 없음, 페이지
    // 왼쪽 끝 = 막대 정가운데 = pivotX) 되어야 그 다음 정지 상태(새
    // 페이지)로 이어질 때 튀지 않습니다.
    final maxTranslateX = _maxLeafTranslateX(frameWidth, frameHeight, barWidthFraction: 0.5);
    final translatePhase = (1.0 - 2.0 * progress.clamp(0.0, 1.0)).clamp(0.0, 1.0);
    final translateX = -maxTranslateX * translatePhase;

    // 앞으로 넘김과 같은 이유로 ClipRect 없이, 잎이 페이지 영역 밖으로
    // 튀어나올 수 있게 둡니다. (Stack 자신의 Clip.none이 필요한 이유는
    // _buildForwardScene의 같은 주석 참고.)
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        _buildStaticPageShadow(),
        Positioned.fill(child: RepaintBoundary(child: widget.frontPage)),
        // frontPage(바닥에 깔린 현재 페이지)도 자기 탭을 갖고 있는 것처럼,
        // 정지 상태와 동일하게 그대로(회전 없이) 얹어둡니다.
        if (widget.activeTab != null) widget.activeTab!,
        _buildLeaf(
          angle: angle,
          bend: bend,
          cornerLead: cornerLead,
          liveFallback: widget.prevPage!,
          translateX: translateX,
          tab: widget.activeTab,
        ),
      ],
    );
  }

  /// 페이지 박스 자리에 항상 그려두는, 왜곡되지 않는 정적 그림자입니다.
  /// diary_screen.dart의 `_buildFlipLeaf`는 더 이상 자체 boxShadow를 갖지
  /// 않습니다 — 넘어가는 잎은 스냅샷을 3D로 휘게 만드는데, 그림자가 그
  /// 스냅샷 안에 있으면 메시를 따라 같이 휘어져(원래 가장자리에만 있던
  /// 그림자가 대각선으로 크게 번진 것처럼) 정지 상태와 다르게 보였습니다.
  /// 그림자를 이 별도 레이어로 분리해 항상 같은 자리에 고정해두면, 넘기는
  /// 중이든 정지 상태든(바닥에 깔린 backPage/frontPage 뒤로) 항상 동일하게
  /// 보입니다.
  Widget _buildStaticPageShadow() {
    return Positioned(
      top: DiaryPageFrame.defaultPageTop,
      bottom: DiaryPageFrame.defaultPageBottom,
      left: DiaryPageFrame.defaultPageLeft,
      right: DiaryPageFrame.defaultPageRight,
      child: FractionallySizedBox(
        widthFactor: DiaryPageFrame.defaultPageWidthFactor,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: DiaryPageFrame.defaultPageBorderRadius,
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(5, 5)),
            ],
          ),
        ),
      ),
    );
  }

  /// 넘어가는 페이지 잎 한 장. 스냅샷([_leafImage])이 준비됐으면 곡면으로,
  /// 아직이면(드래그 첫 1~2프레임 또는 캡처 실패) 평면 회전으로 그립니다.
  /// 세로 넘김(flipUpward)은 다이어리에서 쓰지 않아 곡면을 지원하지 않습니다.
  Widget _buildLeaf({
    required double angle,
    required double bend,
    required double cornerLead,
    required Widget liveFallback,
    double translateX = 0,
    Widget? tab,
  }) {
    final image = _leafImage;
    final shader = _leafShader;
    final Widget content;
    if (image == null || shader == null || widget.flipUpward) {
      final matrix = Matrix4.identity()..setEntry(3, 2, 0.001);
      if (widget.flipUpward) {
        matrix.rotateX(angle);
      } else {
        matrix.rotateY(angle);
      }
      content = Positioned.fill(
        child: Transform.translate(
          offset: Offset(translateX, 0),
          child: Transform(
            transform: matrix,
            alignment: widget.flipUpward
                ? Alignment.topCenter
                : Alignment.centerLeft,
            child: RepaintBoundary(child: liveFallback),
          ),
        ),
      );
    } else {
      content = Positioned.fill(
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
            pivotX: widget.pivotX,
            translateX: translateX,
            columns: _bendColumns,
            rows: _bendRows,
          ),
        ),
      );
    }

    if (tab == null) return content;

    // 탭은 메시(행마다 다른 회전각+원근 왜곡)에 포함시키지 않고, 잎과
    // 같은 각도로 단순 평면 회전(rotateY/X)만 적용해서 별도로 그립니다.
    // 책등(pivotX)에서 아주 먼 자리라 메시에 포함되면 조각나듯 깨져
    // 보였습니다.
    final tabMatrix = Matrix4.identity()..setEntry(3, 2, 0.001);
    if (widget.flipUpward) {
      tabMatrix.rotateX(angle);
    } else {
      tabMatrix.rotateY(angle);
    }
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        content,
        Positioned.fill(
          child: Transform.translate(
            offset: Offset(translateX, 0),
            child: Transform(
              transform: tabMatrix,
              alignment: widget.flipUpward
                  ? Alignment.topCenter
                  : Alignment.centerLeft,
              // tab은 이미 Positioned로 위치가 잡혀 있어(activeTab 문서 참고),
              // Stack 없이 바로 Transform의 자식으로 두면 ParentDataWidget
              // 오류가 납니다. 이 안쪽 Stack도 여백 밖으로 튀어나가는 탭이
              // 잘리지 않도록 Clip.none이 필요합니다.
              child: Stack(fit: StackFit.expand, clipBehavior: Clip.none, children: [tab]),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _disposeLeafImage();
    _controller.dispose();
    _backController.dispose();
    super.dispose();
  }
}

/// 페이지 스냅샷을 (columns × rows) 격자 메시로 나눠, 정점마다 책등(x=0)
/// 쪽부터 누적되는 회전각으로 3D 위치를 계산하고 원근 투영해
/// [Canvas.drawVertices]로 그립니다. 조각별 클리핑 없이 하나의 텍스처
/// 메시라 이음새가 없습니다.
///
/// [DiaryPageFlipper]의 실제 페이지 넘김뿐 아니라, 인덱스 탭 전환
/// ([DiaryTabFlipRoute])의 빈 속지도 이 페인터를 그대로 써서 두 넘김이
/// 완전히 같은 곡면/음영으로 보입니다 — 그래서 공개 클래스입니다.
///
/// - 가로 방향: 접선 각도가 뿌리(책등) `angle·(1-bend/2)`에서 잎 끝
///   `angle·(1+bend/2)`까지 선형으로 늘어납니다 — 잎 끝이 뿌리보다 더
///   돌아가 있어 실제 종이의 휘어짐과 같은 방향입니다.
/// - 세로 방향: [cornerLead]만큼 아래쪽 행의 회전각이 위쪽 행보다 커서,
///   오른쪽 아래 모서리부터 들리며(또는 마지막까지 들려 있다가 내려앉으며)
///   넘어가는 대각선 페이지 컬이 됩니다.
class BentLeafPainter extends CustomPainter {
  final ui.Image image;

  /// 캡처 시 한 번 만들어 매 프레임 재사용하는 셰이더/버퍼들.
  /// (프레임마다 새로 만들면 시뮬레이터에서 눈에 띄게 버벅입니다.)
  final ui.ImageShader shader;
  final Float32List positions;
  final Float32List texCoords;
  final Int32List colors;
  final Uint16List indices;

  /// 책등 기준 전체 회전각(라디안).
  final double angle;

  /// 곡률 강도(잎 끝과 뿌리의 회전각 차이 비율). 0이면 평면.
  final double bend;

  /// 아래쪽 행이 위쪽 행보다 더 돌아가는 비율(0이면 위아래 균일).
  final double cornerLead;

  /// 회전축(책등)의 x좌표. 이보다 왼쪽 영역은 회전하지 않고 제자리.
  final double pivotX;

  /// 넘어가는 동안 잎 전체에 추가로 더해지는 왼쪽 이동(px, 음수).
  final double translateX;
  final int columns;
  final int rows;

  BentLeafPainter({
    required this.image,
    required this.shader,
    required this.positions,
    required this.texCoords,
    required this.colors,
    required this.indices,
    required this.angle,
    required this.bend,
    required this.cornerLead,
    required this.pivotX,
    required this.translateX,
    required this.columns,
    required this.rows,
  });

  /// 기존 평면 회전(Transform + setEntry(3,2,0.001))과 같은 원근 계수.
  static const double _perspective = 0.001;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final colW = size.width / columns;
    final cy = size.height / 2;
    // 회전하는 영역(책등 오른쪽) 폭. pivotX 왼쪽은 제자리에 남습니다.
    final usable = (size.width - pivotX).clamp(1.0, double.infinity);

    // 프레임마다 변하는 것은 정점 위치와 음영뿐이므로, 캡처 시 할당해 둔
    // 버퍼를 덮어씁니다(Vertices.raw가 내부에서 복사해 가므로 안전).
    for (var j = 0; j <= rows; j++) {
      final v = j / rows; // 0(위) ~ 1(아래)
      final y = v * size.height;
      // 아래쪽 행일수록 더 돌아가고 위쪽 행은 덜 돌아갑니다(평균은 1).
      final rowFactor = (1 + cornerLead * (v - 0.5)).clamp(0.0, 2.0);

      // 책등(pivotX)에서 잎 끝까지 접선 각도를 적분해 이 행의 곡선을
      // 만듭니다. 책등 왼쪽 열들은 회전하지 않은 원래 좌표 그대로입니다.
      var x3d = pivotX;
      var z3d = 0.0;
      var prevFlat = 0.0;
      for (var i = 0; i <= columns; i++) {
        final idx = j * (columns + 1) + i;
        final flat = i * colW;

        if (flat <= pivotX) {
          // 책등 왼쪽: 제자리(투명한 페이지 여백 영역). translateX만 반영.
          positions[idx * 2] = flat + translateX;
          positions[idx * 2 + 1] = y;
          colors[idx] = 0xFFFFFFFF;
        } else {
          // 직전 경계(또는 책등)에서 이번 경계까지, 구간 중간 지점의 접선
          // 방향으로 전진합니다.
          final segStart = math.max(prevFlat, pivotX);
          final segLen = flat - segStart;
          final midF = (((segStart + flat) / 2 - pivotX) / usable).clamp(
            0.0,
            1.0,
          );
          final t = rowFactor * angle * (1 - bend / 2 + bend * midF);
          x3d += segLen * math.cos(t);
          z3d += -segLen * math.sin(t);

          // 원근 투영(w = 1 + z·perspective, 세로는 중앙 기준).
          final w = 1.0 + z3d * _perspective;
          positions[idx * 2] = pivotX + (x3d - pivotX) / w + translateX;
          positions[idx * 2 + 1] = (y - cy) / w + cy;

          // 접선이 설수록 빛을 덜 받아 어두워지는 음영(정점 색으로 보간).
          final f = ((flat - pivotX) / usable).clamp(0.0, 1.0);
          final tangent = rowFactor * angle * (1 - bend / 2 + bend * f);
          final shade = (1 - math.cos(tangent)).clamp(0.0, 1.0) * 0.18;
          final lum = ((1 - shade) * 255).round().clamp(0, 255);
          colors[idx] = 0xFF000000 | (lum << 16) | (lum << 8) | lum;
        }
        prevFlat = flat;
      }
    }

    // 예전엔 잎이 들릴수록 아래 페이지/링 위에 별도의 그림자를 추가로
    // 드리웠는데, 이게 정지 상태에는 없다가 넘기는 도중에만 나타나서
    // 페이지·바인더 링의 그림자가 넘김 여부에 따라 다르게 보였습니다.
    // 페이지 자체(_buildFlipLeaf의 boxShadow)와 링(_BinderRing의
    // boxShadow+테두리)이 이미 항상 그림자를 갖고 있으므로, 넘기는 중에만
    // 추가되는 이 그림자는 없애 정지 상태와 항상 같은 모양을 유지합니다.

    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: texCoords,
      colors: colors,
      indices: indices,
    );

    canvas.drawVertices(
      vertices,
      BlendMode.modulate,
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(covariant BentLeafPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.angle != angle ||
      oldDelegate.bend != bend ||
      oldDelegate.cornerLead != cornerLead ||
      oldDelegate.pivotX != pivotX ||
      oldDelegate.translateX != translateX ||
      oldDelegate.columns != columns ||
      oldDelegate.rows != rows;
}
