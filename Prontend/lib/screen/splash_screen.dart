import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:ticketdiary/screen/diary_screen.dart';
import 'package:ticketdiary/services/app_settings_store.dart';
import 'package:ticketdiary/services/auth_service.dart';
import 'package:ticketdiary/services/fcm_service.dart';
import 'package:ticketdiary/widgets/diary_page_flipper.dart'
    show BentLeafPainter, DiaryPageFlipper;
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';
import 'package:ticketdiary/widgets/responsive_text.dart'
    show kMaxTextScale, kMinTextScale, kReferenceFrameWidth;

// [백엔드 수정]
// 다이어리 탭 페이지 넘김과 같은 곡면 렌더링(BentLeafPainter)을 스플래시
// 인트로에도 사용. 예전 방식(splash_screen_old.dart)은 죽은 코드로 남김.

/// 앱 실행 시 보여주는 시작 애니메이션.
///
/// 나무 테이블 위에 놓인 닫힌 가죽 다이어리를 천천히 줌인하다가, 표지가
/// 왼쪽으로 열리고 속지들이 촤라락 넘어가는 동안에도 페이지 가운데를 향해
/// 계속 줌이 진행됩니다. 마지막 페이지가 넘어가며 촤라락이 멈추는 순간, 화면을
/// 가득 채운 페이지 위로 실제 다이어리 인덱스 화면이 서서히 겹쳐(페이드)
/// 자연스럽게 이어집니다. 애니메이션이 재생되는 동안 내부 데이터 로딩
/// ([AppSettingsStore.load] 등)도 함께 진행됩니다.
///
/// 이미지 에셋 없이(현재 앱 전체가 그렇듯) CustomPainter로 나무결/가죽 질감을
/// 그려서, 기존 다이어리 프레임([DiaryPageFrame])과 같은 배색(가죽 갈색 /
/// 속지 크림색)을 유지합니다.
///
/// 속지는 실제 다이어리 페이지와 정확히 같은 비율([DiaryPageFrame.diaryAspectRatio])입니다.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // 다이어리 프레임(diary_page_frame.dart)과 통일감 있는 배색.
  static const Color _coverColor = Color(0xFF5C4033);
  static const Color _pageColor = Color(0xFFF4F1E1);

  /// 속지 규격의 기준(세로/가로 비율). 예전엔 A4(297/210)를 썼는데, 실제
  /// [DiaryPageFrame.diaryAspectRatio](가로/세로)와 안 맞아서 펼침 애니메이션
  /// 속 페이지가 실제 다이어리 페이지보다 세로로 길어 보이는 문제가
  /// 있었습니다. 실제 다이어리와 같은 비율을 쓰도록 여기서 반전해 씁니다.
  static const double _pageRatio = 1 / DiaryPageFrame.diaryAspectRatio;

  /// 애니메이션 도중(화면을 다 채우기 전까지) 보이는 겉 가죽케이스를 이
  /// 배율만큼 더 크게 보여줍니다. 최종 페이지 크기에는 영향이 없습니다.
  static const double _bookSizeBoost = 1.2;

  // ---- 닫힌 책 장식 요소 비율(책 폭 w / 높이 h 기준) ----
  // 아래 값들은 예전에 고정 픽셀(아이폰17 기준 book≈251x441)로 짜여
  // 있어서, 화면 비율이 달라 책 크기가 달라지는 다른 기기(아이패드 등)
  // 에서는 책 대비 장식 크기가 어긋나 보였습니다. bookWidth/bookHeight는
  // 항상 diaryAspectRatio를 유지하며 기기별로 커지거나 작아지므로, 이
  // 값들을 w(또는 h) 비율로 표현해두면 어느 기기에서든 책과 같은 비율로
  // 스케일됩니다(원래 픽셀값 / 아이폰17 기준 book 크기로 환산).
  static const double _edgeInsetRatio = 0.0239; // 6 / 250.85
  static const double _edgeInsetRatioV = 0.01133; // 5 / 441.3
  static const double _edgeRadiusRatio = 0.01993; // 5 / 250.85
  static const double _edgeShadowBlurRatio = 0.0877; // 22 / 250.85
  static const double _edgeShadowOffsetRatio = 0.02719; // 12 / 441.3
  static const double _ribbonProtrudeRatio = 0.02946; // 13 / 441.3
  static const double _ribbonWidthRatio = 0.03588; // 9 / 250.85
  static const double _ribbonHeightRatio = 0.05439; // 24 / 441.3
  static const double _ribbonRadiusRatio = 0.00797; // 2 / 250.85
  static const double _coverRadiusRatio = 0.0279; // 7 / 250.85
  static const double _coverShadowBlurRatio = 0.07176; // 18 / 250.85
  static const double _coverShadowOffsetXRatio = 0.00797; // 2 / 250.85
  static const double _coverShadowOffsetYRatio = 0.02266; // 10 / 441.3
  static const double _coverEdgeHighlightWidthRatio = 0.04784; // 12 / 250.85
  static const double _bandInsetRatio = 0.00453; // 2 / 441.3
  static const double _bandRadiusRatio = 0.01196; // 3 / 250.85
  static const double _bandShadowOffsetXRatio = 0.00399; // 1 / 250.85
  static const double _coverTitleGapRatio = 0.02266; // 10 / 441.3

  static const Duration _totalDuration = Duration(milliseconds: 4000);

  // ---- 타임라인(전체 0.0~1.0 기준 구간) ----
  /// 0. 책이 화면 위에서 테이블로 깃털처럼 천천히 내려와 착지. 줌인/표지
  /// 열림 등 나머지 타임라인은 그대로 두고, 이 구간에만 별도로 세로
  /// 낙하 + 좌우 흔들림 + 착지 스쿼시를 얹습니다.
  static const double _dropEnd = 0.20;

  /// 1. 닫힌 다이어리를 화면의 약 80%까지 천천히 줌인.
  static const double _zoomInEnd = 0.32;

  /// 2. 표지가 왼쪽으로 열리기 시작(줌은 계속 진행).
  static const double _coverStart = 0.30;
  static const double _coverEnd = 0.50;

  /// 3. 속지들이 연달아 촤라락 넘어감(줌도 계속 진행).
  static const double _flipStart = 0.44;
  static const int _flipCount = 5;
  static const double _flipStagger = 0.07;
  static const double _flipDuration = 0.13; // 마지막 장은 ~0.85에 끝남

  /// 마지막 속지(4번 장, [_flipCount]-1)가 90도(p=0.5, 완전히 세워진 순간 -
  /// 다 넘어가 눕는 정착까지 기다리지 않음)까지 넘어간 시각. 바인더 링을
  /// "마지막 페이지(=[_MainPageReplica]) 나오기 직전 페이지가 90도쯤
  /// 넘어가면 갑자기 보이도록" 하는 기준점으로 씁니다(아래 바인더 링
  /// 렌더링 참고).
  static const double _binderRingRevealAt =
      _flipStart + (_flipCount - 1) * _flipStagger + 0.5 * _flipDuration;

  /// 4. 페이지(가운데 시선 고정)가 화면을 가득 채울 때까지 줌.
  ///
  /// [백엔드 수정]
  /// 줌 종료를 0.97 -> 0.82로 당김 - [_finalFlipStart](0.86)보다 확실히
  /// 먼저 끝나 book 배율(bookGrowth)이 고정된 뒤 마지막 장이 넘어가게 함.
  static const double _zoomPageStart = 0.38;
  static const double _zoomPageEnd = 0.82;

  /// 5. 마지막 장(=[_MainPageReplica], 그동안 계속 정지해있던 흰 페이지)도
  /// 다른 속지들과 똑같이 넘어가 사라집니다. 예전엔 이 페이지가 가만히
  /// 있다가 실제 화면과 페이드로만 겹쳐졌는데, 이제는 이 페이지 자체가
  /// 넘어가면서 그 자리에 진짜 화면이 나타나는 느낌을 노렸습니다.
  /// [_zoomPageEnd](0.82)가 다 끝나고 약간의 여유(0.04) 뒤에 시작해서,
  /// book 배율이 확실히 안정된 뒤에 미리보기가 뜨도록 합니다.
  static const double _finalFlipStart = 0.86;
  static const double _finalFlipDuration = 0.11;
  static const double _finalFlipAngle = math.pi * 0.56; // 약 100도.

  // [백엔드 수정]
  // 미리보기 세로 보정 매직 넘버 제거, DiaryPageFrame.scaleOverride/
  // marginEachSideOverride로 대체.

  /// 마지막 장이 90도를 넘어 사실상 안 보이게 된 시점에 진짜 화면으로
  /// 넘어갑니다. 정적인 페이지가 페이드로 사라지는 대신, 페이지가 실제로
  /// 넘어가는 도중 그 자리에 진짜 화면이 자연스럽게 이어받는 느낌입니다.
  static const double _navigateAt = 0.96;

  /// [백엔드 수정]
  /// 크로스페이드 완전히 제거(지속 시간 0) - 겹쳐 보이는 프레임 자체를 없앰.
  static const Duration _fadeToMainDuration = Duration.zero;

  late final AnimationController _controller;

  bool _dataReady = false;
  bool _navigated = false;

  // BentLeafPainter용 장별 텍스처(비동기 생성이라 준비 전엔 null - 그동안은
  // 기존 단순 회전으로 폴백). 인덱스는 cols/rows에만 의존해 전체 장이
  // 공유하지만, 이미지/셰이더/텍스처 좌표는 장마다 따로 갖습니다.
  final List<ui.Image?> _leafImages = List<ui.Image?>.filled(_flipCount, null);
  final List<ui.ImageShader?> _leafShaders = List<ui.ImageShader?>.filled(
    _flipCount,
    null,
  );
  final List<Float32List?> _leafTexCoords = List<Float32List?>.filled(
    _flipCount,
    null,
  );
  Uint16List? _leafIndices;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _totalDuration)
      ..addListener(_onTick)
      ..forward();
    unawaited(_loadData());
    unawaited(_prepareLeafAssets());
  }

  /// 넘어가는 속지 5장의 텍스처를 준비합니다. 장마다 미묘하게 다른 톤
  /// (`Color.lerp(_pageColor, Colors.white, i*0.045)`)을 직접 캔버스에
  /// 그려 넣습니다(실제 다이어리 페이지는 위젯을 캡처하지만, 스플래시
  /// 속지는 위젯이 아니라 이렇게 그린 결과를 이미지로 떠서 씁니다).
  Future<void> _prepareLeafAssets() async {
    const cols = DiaryPageFlipper.bendColumns;
    const rows = DiaryPageFlipper.bendRows;

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

    final images = <ui.Image>[];
    final shaders = <ui.ImageShader>[];
    final texCoordsList = <Float32List>[];
    for (var i = 0; i < _flipCount; i++) {
      final tint = Color.lerp(_pageColor, Colors.white, i * 0.045)!;
      // [백엔드 수정]
      // "TICKET DIARY" 로고를 0번 장에서 마지막 페이지로 이동. 이제 모든
      // 장이 단색 속지(_renderSolidLeafImage).
      final image = await _renderSolidLeafImage(tint);
      final shader = ui.ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        Matrix4.identity().storage,
        filterQuality: FilterQuality.medium,
      );
      final imgW = image.width.toDouble();
      final imgH = image.height.toDouble();
      final texCoords = Float32List((cols + 1) * (rows + 1) * 2);
      for (var j = 0; j <= rows; j++) {
        for (var c = 0; c <= cols; c++) {
          final idx = j * (cols + 1) + c;
          texCoords[idx * 2] = (c / cols) * imgW;
          texCoords[idx * 2 + 1] = (j / rows) * imgH;
        }
      }
      images.add(image);
      shaders.add(shader);
      texCoordsList.add(texCoords);
    }

    if (!mounted) {
      for (final image in images) {
        image.dispose();
      }
      return;
    }

    setState(() {
      for (var i = 0; i < _flipCount; i++) {
        _leafImages[i] = images[i];
        _leafShaders[i] = shaders[i];
        _leafTexCoords[i] = texCoordsList[i];
      }
      _leafIndices = indices;
    });
  }

  /// [백엔드 수정]
  /// 텍스처 오른쪽 끝만 둥근 모서리로(DiaryPageFrame.defaultPageBorderRadius와
  /// 통일). 텍스처 폭 비례 비율로 근사(정확한 px는 레이아웃 전이라 모름).
  static const double _leafCornerRadiusRatio = 0.045;

  /// 오른쪽 끝만 둥근 단색 이미지 - 텍스트가 없는 1~4번 장용. 모서리가
  /// 뭉개지지 않도록 어느 정도 해상도를 둡니다(예전 8x8은 색만 있으면
  /// 충분했지만 둥근 모서리를 표현하기엔 너무 작았습니다).
  Future<ui.Image> _renderSolidLeafImage(Color tint) async {
    const width = 160.0;
    final height = width * _pageRatio;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
    final rrect = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, 0, width, height),
      topRight: Radius.circular(width * _leafCornerRadiusRatio),
      bottomRight: Radius.circular(width * _leafCornerRadiusRatio),
    );
    canvas.drawRRect(rrect, Paint()..color = tint);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width.round(), height.round());
    picture.dispose();
    return image;
  }

  Future<void> _loadData() async {
    // 여기서 실제 내부 데이터 로딩을 진행합니다. 나중에 추가 로딩이 필요해지면
    // 이 안에 이어서 await 하면 애니메이션과 함께 대기됩니다.
    //
    // 로딩이 어떤 이유로든 지나치게 오래 걸리거나 멈춰도 앱이 스플래시에
    // 갇히지 않도록, 애니메이션 길이보다 조금 긴 타임아웃을 둡니다.
    final timeout = _totalDuration + const Duration(seconds: 2);
    await Future.wait([
      AppSettingsStore.instance.load(),
      // 저장된 로그인 세션을 불러오거나(없으면) 게스트 세션을 새로 만듭니다.
      AuthService.instance.ensureSession(),
    ]).timeout(timeout, onTimeout: () => const []);

    // [백엔드 수정]
    // FCM 초기화를 fire-and-forget으로 분리 - 스플래시를 막지 않음.
    unawaited(FcmService.instance.init());
    if (!mounted) return;
    _dataReady = true;
    // 마지막 장이 넘어가길 기다리며 [_onTick]에서 멈춰뒀다면 이어서 재생.
    if (!_controller.isAnimating && _controller.value < 1.0) {
      _controller.forward();
    }
    _maybeNavigate();
  }

  void _onTick() {
    // [백엔드 수정]
    // 데이터 미준비 시 [_finalFlipStart]에서 애니메이션 정지, [_loadData]에서
    // 이어서 재생.
    if (!_dataReady &&
        _controller.isAnimating &&
        _controller.value >= _finalFlipStart) {
      _controller.stop();
      return;
    }
    if (_controller.value >= _navigateAt) _maybeNavigate();
  }

  /// 마지막 장이 넘어가 사실상 안 보이게 된 시점([_navigateAt]) 이후 + 데이터
  /// 준비 완료일 때 메인 화면을 겹쳐 올립니다. 짧은 페이드가 진행되는 동안 이
  /// 화면의 남은 줌 애니메이션은 아래에서 계속 재생되므로 전환이 끊겨 보이지
  /// 않습니다. 데이터가 더 늦게 끝나면 마지막 프레임(넘어간 뒤)에서 대기합니다.
  void _maybeNavigate() {
    if (_navigated || !mounted) return;
    if (!_dataReady || _controller.value < _navigateAt) return;
    _navigated = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        settings: const RouteSettings(name: DiaryRoutes.diary),
        transitionDuration: _fadeToMainDuration,
        pageBuilder: (_, _, _) => const DiaryScreen(),
        // [백엔드 수정]
        // 페이드 끝나기 전까진 IgnorePointer로 터치 차단.
        transitionsBuilder: (_, animation, _, child) => IgnorePointer(
          ignoring: animation.status != AnimationStatus.completed,
          child: FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    for (final image in _leafImages) {
      image?.dispose();
    }
    super.dispose();
  }

  /// 전체 진행도 [t]를 [a, b] 구간의 0.0~1.0 진행도로 변환합니다.
  static double _seg(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 만에 하나 장면이 채우지 못하는 틈이 생겨도 흰 배경 대신 테이블과 같은
      // 톤이 보이도록 해둡니다.
      backgroundColor: const Color(0xFF3A281B),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 실제 DiaryPageFrame은 SafeArea 안에서 크기를 잡는데(노치/상태
          // 표시줄/홈 인디케이터만큼 화면보다 작음), 여기 Scaffold.body는
          // SafeArea를 쓰지 않아 화면 전체 크기를 기준으로 계산되고
          // 있었습니다. 그 차이만큼 애니메이션 끝의 페이지가 실제 다이어리
          // 페이지보다 커 보였던 것이라, 여기서도 같은 SafeArea 여백을
          // 빼서 계산합니다.
          final safePadding = MediaQuery.of(context).padding;
          final screenW =
              constraints.maxWidth - safePadding.left - safePadding.right;
          final screenH =
              constraints.maxHeight - safePadding.top - safePadding.bottom;

          // 실제 DiaryPageFrame은 SafeArea 안쪽(=screenW x screenH) 박스의
          // 한가운데에 놓입니다 - 그 박스는 전체 화면(constraints)의 정중앙이
          // 아니라, 위/아래(또는 좌/우) 여백이 서로 다르면 그만큼 한쪽으로
          // 치우친 자리에 있습니다(예: 상태표시줄(top)만 있고 아래(bottom)엔
          // 제스처 인셋이 거의 없는 기기라면, 실제 프레임은 화면 정중앙보다
          // 살짝 아래에 위치). 아래 [_buildScene]은 지금까지 이 책을 그냥
          // 전체 화면(constraints)의 정중앙에 놓고 있어서, 실제 화면과
          // 위아래(또는 좌우) 위치가 살짝 어긋나 보였습니다. 그 차이만큼
          // 미리 상쇄해둡니다.
          final centeringOffset = Offset(
            (safePadding.left - safePadding.right) / 2,
            (safePadding.top - safePadding.bottom) / 2,
          );

          // 속지가 실제 다이어리와 같은 비율이 되도록 크기를 잡습니다.
          // _bookSizeBoost는 애니메이션이 진행되는 동안(화면을 다 채우기
          // 전까지) 보이는 겉 가죽케이스 자체를 더 크게 보이도록 키우는
          // 배율입니다. fillScale이 항상 "bookWidth * fillScale = 실제
          // 화면 크기"가 되도록 스스로 맞춰지므로, 다 자란 뒤 최종 페이지
          // 크기(실제 DiaryPageFrame과 정확히 일치)에는 영향이 없습니다.
          final bookWidth =
              _bookSizeBoost *
              math.min(screenW * 0.52, screenH * 0.6 / _pageRatio);
          final bookHeight = bookWidth * _pageRatio;

          // 마지막에 페이지가 실제 다이어리 화면과 같은 크기가 되는 배율.
          // 실제 DiaryPageFrame은 SafeArea 안에서 Center+AspectRatio로
          // "꽉 채우기(cover)"가 아니라 "안에 맞추기(contain)"로 배치되므로
          // (한쪽 축은 화면에 딱 맞고 다른 쪽엔 여백), 여기서도 같은 min을
          // 써야 합니다. 예전엔 math.max에 1.04배까지 더해서 일부러 화면을
          // 살짝 넘치게 채웠는데, 그 결과 애니메이션 끝의 페이지가 실제
          // 다이어리 페이지보다 커 보이는 문제가 있었습니다.
          final fillScale = math.min(screenW / bookWidth, screenH / bookHeight);

          // 실제 DiaryPageFrame이 이 화면에서 스스로 계산할 scale/marginEachSide와
          // 정확히 같은 수식(diary_page_frame.dart의 계산과 동일 - frameWidth는
          // "안에 맞추기(contain)"로 정해진 페이지 폭, marginEachSide는 그 페이지가
          // 화면 폭을 다 못 채울 때(아이패드 등) 남는 좌우 여백의 절반)입니다.
          // 미리보기 안 DiaryScreen이 스스로 다시 측정하지 않고 이 값을 그대로
          // 쓰도록 [DiaryScreen.frameScaleOverride]/[frameMarginOverride]로
          // 주입합니다 - 미리보기는 t>=_finalFlipStart일 때만 뜨는데, 그 시점엔
          // bookGrowth가 이미 fillScale로 고정된 뒤라(_zoomPageEnd=0.82 <
          // _finalFlipStart=0.86) 애니메이션 중 다시 계산할 필요 없이 한 번만
          // 구하면 됩니다.
          final frameWidthReal = bookWidth * fillScale;
          final previewScale = (frameWidthReal / kReferenceFrameWidth).clamp(
            kMinTextScale,
            kMaxTextScale,
          );
          final previewMarginEachSide = math.max(
            0.0,
            (screenW - frameWidthReal) / 2,
          );

          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => _buildScene(
              bookWidth,
              bookHeight,
              fillScale,
              _controller.value,
              previewScale,
              previewMarginEachSide,
              centeringOffset,
            ),
          );
        },
      ),
    );
  }

  /// 시작 시점에 다이어리가 테이블 위에서 차지하는 크기 비율.
  /// 장면 전체가 하나의 배율로 확대되므로, 다이어리는 처음부터 이 크기로
  /// "테이블에 놓여" 있고 카메라가 다가가며 화면에 들어차게 됩니다.
  static const double _bookStartScale = 0.34;

  Widget _buildScene(
    double bookW,
    double bookH,
    double fillScale,
    double t,
    double previewScale,
    double previewMarginEachSide,
    Offset centeringOffset,
  ) {
    // 줌: 작게 시작 -> 화면 80%(배율 1.0 근처) -> 페이지가 화면을 가득 채울 때까지.
    final zoomIn = Curves.easeInOut.transform(_seg(t, 0.0, _zoomInEnd));
    final zoomPage = Curves.easeInOut.transform(
      _seg(t, _zoomPageStart, _zoomPageEnd),
    );

    // 다이어리가 화면에서 차지해야 할 목표 배율(작게 -> 80% -> 꽉 참).
    final bookGrowth =
        (_bookStartScale + 0.61 * zoomIn) + (fillScale - 0.95) * zoomPage;

    // 테이블 위의 모든 것(테이블, 소품, 다이어리)은 같은 평면에 놓여 있으므로,
    // 카메라가 다가갈 때 전부 "같은 배율"로 커져야 자연스럽습니다. 그래서
    // 다이어리를 처음부터 작게(_bookStartScale) 놓고, 장면 전체를 하나의
    // 배율로 확대합니다. 시작 배율이 정확히 1.0이라 흰 배경도 드러나지 않습니다.
    final sceneScale = bookGrowth / _bookStartScale;

    // [백엔드 수정]
    // 책이 테이블로 내려오는 구간(_dropEnd까지) - 위→아래 이동 대신 렌즈
    // 앞에서 멀어지며(dropScale 축소) 착지하는 원근감으로 구현.
    final dropT = _seg(t, 0.0, _dropEnd);
    final dropEase = Curves.easeOutQuart.transform(dropT);
    final dropScale = 1.0 + 6.6 * (1.0 - dropEase);
    final dropOffsetY = -bookH * 0.84 * (1.0 - dropEase);
    // 흔들림 진폭은 (1-dropEase)에 비례해 착지할수록 잦아듭니다.
    final swayOffsetX =
        bookW * 0.03 * math.sin(dropT * math.pi * 2.4) * (1.0 - dropEase);
    final squashT = _seg(t, _dropEnd * 0.85, _dropEnd);
    final squash = math.sin(math.pi * squashT.clamp(0.0, 1.0)) * 0.02;

    // [백엔드 수정]
    // 착지 직후 먼지가 퍼졌다 가라앉는 효과 추가(_dropEnd*0.85~+0.07).
    final dustT = _seg(t, _dropEnd * 0.85, _dropEnd + 0.07);

    // 카메라 시선은 처음부터 끝까지 페이지 가운데에 고정합니다.
    const alignment = Alignment.center;

    return Transform.scale(
      scale: sceneScale,
      alignment: alignment,
      child: Stack(
        children: [
          const Positioned.fill(
            child: CustomPaint(
              painter: _RoomTablePainter(),
              child: SizedBox.expand(),
            ),
          ),
          if (dustT > 0.0 && dustT < 1.0)
            Positioned.fill(
              child: CustomPaint(
                painter: _DustBurstPainter(
                  progress: dustT,
                  bookW: bookW,
                  bookH: bookH,
                ),
              ),
            ),
          Center(
            child: Transform.translate(
              // centeringOffset은 실제 화면 px 기준 - 바깥 Transform.scale
              // 안쪽이라 sceneScale로 나눠서 상쇄. 배경은 영향 없이 책만 밀림.
              offset:
                  Offset(swayOffsetX, dropOffsetY) +
                  centeringOffset / sceneScale,
              child: Transform.scale(
                scaleX: _bookStartScale * dropScale * (1.0 + squash * 0.6),
                scaleY: _bookStartScale * dropScale * (1.0 - squash),
                child: _buildBook(
                  bookW,
                  bookH,
                  t,
                  fillScale,
                  bookGrowth,
                  previewScale,
                  previewMarginEachSide,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBook(
    double w,
    double h,
    double t,
    double fillScale,
    double bookGrowth,
    double previewScale,
    double previewMarginEachSide,
  ) {
    final coverT = _seg(t, _coverStart, _coverEnd);
    final zoomPage = Curves.easeInOut.transform(
      _seg(t, _zoomPageStart, _zoomPageEnd),
    );

    // 다이어리 내부(복제본) 속 실제 "페이지 종이" 영역. 촤라락 넘어가는
    // 속지들이 이 영역과 같은 크기/위치로 넘어가도록 계산합니다.
    // (_MainPageReplica의 배치 계산과 동일한 식입니다.)
    //
    // w x h(=bookWidth x bookHeight)는 이미 diaryAspectRatio 그대로이고,
    // fillScale은 "이 책이 다 자라면 정확히 실제 화면의 DiaryPageFrame과
    // 같은 크기가 되는 배율"이므로, k=1/fillScale을 실제 DiaryPageFrame의
    // 페이지 여백(pageTop/Bottom/Left/Right, 실제 화면 px 기준)에 곱하면
    // 지금 책 크기 기준 여백으로 정확히 환산됩니다. 예전엔 여기서 화면
    // 비율로 한 번 더 레터박싱하는 불필요한 단계가 있어서, 다 자란 뒤에도
    // 실제 페이지보다 작게 멈추는 문제가 있었습니다(넘어가는 속지 → 예시
    // 페이지 → 실제 메인 페이지로 이어질 때 크기가 어긋남). [_diaryPageCardRect]
    // 하나로 통일해 크기가 끊김 없이 자연스럽게 이어지도록 합니다.
    final k = 1 / fillScale;
    final pageRect = _diaryPageCardRect(w, h, k);

    // [백엔드 수정]
    // 바인더 링 치수를 DiaryPageFrame.computeRingMetrics와 같은 식으로
    // pageRect 기준 재현(예전 고정값 20x8, 옅은 그림자 대신).
    final binderBarWidth =
        pageRect.width * DiaryPageFrame.binderBarWidthRatio + 5 * k;
    final binderBarHeight =
        pageRect.height * DiaryPageFrame.binderBarHeightRatio;
    final binderCircleDiameter =
        binderBarHeight * DiaryPageFrame.binderCircleToBarHeightRatio;
    final binderCircleShiftX = binderCircleDiameter / 2;
    final binderLeft =
        pageRect.left - binderCircleDiameter - binderBarWidth / 2;

    // 넘어가는 표지/속지가 아래에 드리우는 그림자의 세기.
    // (각 요소의 진행도가 절반일 때 가장 짙고, 시작/끝에는 사라집니다.)
    // 표지는 다이어리 내부 전체에, 속지는 페이지 종이 영역에만 드리웁니다.
    final coverShadow = math.sin(coverT * math.pi);
    var pageShadow = 0.0;
    for (var i = 0; i < _flipCount; i++) {
      final start = _flipStart + i * _flipStagger;
      final p = _seg(t, start, start + _flipDuration);
      pageShadow = math.max(pageShadow, math.sin(p * math.pi));
    }

    // 스플래시에서만 쓰는 종이 외곽선. 마지막 줌 구간에서 서서히 사라져서
    // 메인 페이지(외곽선 없음)와 자연스럽게 겹쳐집니다.
    final outlineAlpha = 0.30 * (1.0 - zoomPage);

    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // ---- 속지 묶음(닫혀있을 때 오른쪽으로 살짝 삐져나와 보이는 종이들) ----
          //
          // [백엔드 수정]
          // opacity 게이팅 없이 항상 그려지던 걸 coverT 반비례로 옅어지게
          // 수정 - 표지가 다 열리면 완전히 사라짐.
          if (coverT < 0.999)
            Positioned(
              left: w * _edgeInsetRatio,
              right: 0,
              top: h * _edgeInsetRatioV,
              bottom: h * _edgeInsetRatioV,
              child: Opacity(
                opacity: 1.0 - coverT,
                child: Container(
                  decoration: BoxDecoration(
                    color: _pageColor,
                    borderRadius: BorderRadius.horizontal(
                      right: Radius.circular(w * _edgeRadiusRatio),
                    ),
                    border: Border.all(
                      color: Colors.black.withValues(alpha: outlineAlpha),
                      width: 0.7,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black45,
                        blurRadius: w * _edgeShadowBlurRatio,
                        offset: Offset(0, h * _edgeShadowOffsetRatio),
                      ),
                    ],
                  ),
                  child: const CustomPaint(painter: _PageEdgesPainter()),
                ),
              ),
            ),

          // 갈피끈(리본). 속지 아래로 삐져나온 디테일.
          //
          // [백엔드 수정]
          // 미리보기가 뜨는 t>=_finalFlipStart부터는 숨김(실제 화면엔 없는
          // 장식이라 계속 삐져나와 보였음).
          if (t < _finalFlipStart)
            Positioned(
              right: w * 0.22,
              bottom: -h * _ribbonProtrudeRatio,
              child: Container(
                width: w * _ribbonWidthRatio,
                height: h * _ribbonHeightRatio,
                decoration: BoxDecoration(
                  color: const Color(0xFFB0413E),
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(w * _ribbonRadiusRatio),
                  ),
                ),
              ),
            ),

          // ---- 고정 가죽 배경(회전하지 않음) ----
          // [백엔드 수정]
          // _MainPageReplica가 넘어가 사라진 뒤 뒤쪽 테이블 무늬가 비쳐
          // 보이던 문제 - 같은 색/모서리 고정 배경을 별도로 깔아 해결.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _MainPageReplica._leatherColor,
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(5),
                ),
              ),
            ),
          ),

          // ---- 실제 화면 미리보기 ----
          //
          // [백엔드 수정]
          // 마지막 장 뒤에 실제 DiaryScreen을 끼워 넣어 페이지가 도는 만큼
          // 드러나게 함(FittedBox+MediaQuery로 book 칸에 크기 맞춤). scene
          // 밖으로 빼는 방법은 화면이 통째로 덮여버려서 되돌림 - 재시도 금지.
          if (t >= _finalFlipStart && _dataReady)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox(
                  width: w * bookGrowth,
                  height: h * bookGrowth,
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      size: Size(w * bookGrowth, h * bookGrowth),
                      padding: EdgeInsets.zero,
                    ),
                    child: IgnorePointer(
                      child: DiaryScreen(
                        frameScaleOverride: previewScale,
                        frameMarginOverride: previewMarginEachSide,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // ---- 표지가 열린 뒤 드러나는, 다이어리 내부(줌의 목적지) ----
          // 실제 메인 화면(DiaryPageFrame + 다이어리 탭 첫 페이지)과 같은
          // 디자인의 축소 복제본. 그대로 확대되다가 진짜 메인 화면과 겹쳐집니다.
          // book(w x h) 전체를 그대로 채워야 [_diaryPageCardRect]가
          // [_buildBook]의 pageRect와 정확히 같은 기준으로 계산됩니다.
          //
          // [백엔드 수정]
          // 다른 속지들처럼 [_finalFlipStart]~+[_finalFlipDuration]에 넘어가
          // 사라짐. book 전체를 꽉 채워 왼쪽 끝=책등이라 pivotX 트릭 불필요.
          Positioned.fill(
            child: Transform(
              alignment: Alignment.centerLeft,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.00016)
                ..rotateY(
                  _seg(
                        t,
                        _finalFlipStart,
                        _finalFlipStart + _finalFlipDuration,
                      ) *
                      _finalFlipAngle,
                ),
              child: _MainPageReplica(
                bookW: w,
                bookH: h,
                fillScale: fillScale,
                outlineAlpha: outlineAlpha,
              ),
            ),
          ),

          // ---- 열리는 표지가 다이어리 내부 전체에 드리우는 그림자(입체감) ----
          if (coverShadow > 0.001)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(5),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withValues(alpha: 0.30 * coverShadow),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.55],
                  ),
                ),
              ),
            ),

          // ---- 넘어가는 속지가 아래 페이지 종이에 드리우는 그림자 ----
          if (pageShadow > 0.001)
            Positioned.fromRect(
              rect: pageRect,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.horizontal(
                    right: Radius.circular(15 * k),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withValues(alpha: 0.30 * pageShadow),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.55],
                  ),
                ),
              ),
            ),

          // ---- 남은 속지가 쌓여있는 듯한 느낌을 주는 배경 레이어 ----
          //
          // [백엔드 수정]
          // DiaryPageFrame.pageLayers처럼 페이지 뒤로 크림색 사각형이 오른쪽에
          // 살짝씩 다르게 삐져나오는 배경 레이어 추가. [_MainPageReplica]보다
          // 뒤(z-order상 앞)에 둬야 표지~마지막 장 전까지 계속 드러나 보임.
          //
          // [백엔드 수정]
          // rect가 pageRect.left부터 시작해 pageRect 전체를 가리던 버그
          // 수정(로고까지 같이 가려짐) - pageRect.right부터만 그리도록 좁힘.
          if (t < _finalFlipStart)
            for (final stickOut in const [10.0, 7.0, 4.0, 1.0])
              Positioned.fromRect(
                rect: Rect.fromLTRB(
                  pageRect.right,
                  pageRect.top,
                  pageRect.right + stickOut * k,
                  pageRect.bottom,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _pageColor,
                    borderRadius: BorderRadius.horizontal(
                      right: Radius.circular(15 * k),
                    ),
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.15),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 8 * k,
                        offset: Offset(4 * k, 4 * k),
                      ),
                    ],
                  ),
                ),
              ),

          // [백엔드 수정]
          // 정착한 순서대로 그려야 쌓이는 더미가 침범 안 함 - 아직 안 정착한
          // 건 항상 위(표지>0번>...>4번 순)로, 매 프레임 재계산.
          ..._buildCoverAndPagesInSettleOrder(t, w, h, pageRect, k, coverT),

          // ---- 왼쪽 바인더 링 ----
          //
          // [백엔드 수정]
          // 링을 페이지/속지보다 항상 위에 그리도록 pageRect 기준으로 직접
          // 그림(예전엔 속지에 가려짐).
          //
          // [백엔드 수정]
          // coverT 페이드인 대신 마지막 속지 90도([_binderRingRevealAt])에서
          // 즉시(컷) 등장. 위치도 DiaryPageFrame._buildRing과 같은 식으로 수정.
          if (t >= _binderRingRevealAt)
            Positioned(
              left: binderLeft,
              top: DiaryPageFrame.defaultBinderTop * k,
              bottom: DiaryPageFrame.defaultBinderBottom * k,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(
                  DiaryPageFrame.defaultBinderRingCount,
                  (_) => _buildMiniBinderRing(
                    k,
                    binderBarWidth,
                    binderBarHeight,
                    binderCircleShiftX,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// [_buildCover]/[_buildFlipPage]를 "정착한 시각" 순으로 정렬해서
  /// 반환합니다 - 가장 먼저 넘어가 정착한 게 맨 아래(리스트 앞쪽), 아직
  /// 활발히 넘어가는 중이거나 시작 전인 건 항상 맨 위(리스트 뒤쪽)에,
  /// 그중에서도 표지가 가장 위 · 0번 장이 그다음 · 4번 장이 가장 아래
  /// 순으로(기존 z-순서와 동일) 옵니다.
  List<Widget> _buildCoverAndPagesInSettleOrder(
    double t,
    double w,
    double h,
    Rect pageRect,
    double k,
    double coverT,
  ) {
    // 정착 안 한(활발히 움직이는 중) 항목에 부여하는 키 - 실제 정착
    // 시각(0.0~1.0대)보다 항상 크면서, 표지 > 0번 장 > ... > 4번 장 순으로
    // 큰 값이 되도록 큼직한 기준값에서 표지는 +10, 각 장은 -i.
    const activeBase = 1000.0;
    final entries = <MapEntry<double, Widget>>[];

    // [백엔드 수정]
    // 표지를 t>=_coverStart일 때만 그리던 걸 제거, 처음부터 항상 그림.
    {
      // _buildCover가 튕김 없이 coverT 한 구간(_coverStart~_coverEnd)
      // 만에 최종 각도까지 다 돌므로, 정착 시각도 그와 같은 _coverEnd.
      const settleAt = _coverEnd;
      final key = t >= settleAt ? settleAt : activeBase + 10;
      entries.add(MapEntry(key, _buildCover(w, h, coverT)));
    }
    for (var i = 0; i < _flipCount; i++) {
      final start = _flipStart + i * _flipStagger;
      final settleAt = start + _flipDuration * 0.5; // p=0.5에 도달하는 시각.
      final key = t >= settleAt ? settleAt : activeBase - i;
      entries.add(MapEntry(key, _buildFlipPage(i, t, pageRect, k)));
    }

    entries.sort((a, b) => a.key.compareTo(b.key));
    return [for (final entry in entries) entry.value];
  }

  /// 넘어가는 속지 한 장의 다 넘어간 뒤 눕는 최종 각도(라디안,
  /// 180도=완전히 뒤집힌 것 기준 92%). 완전한 180도까지 보내면 거의
  /// 정면으로 보여 "눕는다"는 느낌이 안 살아서, 살짝 못 미친 채로
  /// 멈춥니다(책등 반대쪽으로 비스듬히 기대 쌓인 느낌).
  static const double _settleRestAngle = math.pi * 0.92;

  /// 다이어리 탭 페이지 넘김과 같은 곡면(BentLeafPainter) 렌더링을 스플래시
  /// 속지에도 그대로 씁니다. angle/bend/cornerLead 공식은
  /// DiaryPageFlipper._buildForwardScene과 동일하게 맞춰서(p를 그대로
  /// progress로 사용) 같은 느낌이 나도록 했습니다.
  ///
  /// [백엔드 수정]
  /// 90도 넘으면 사라지던 걸, 계속 눕다가 [_settleRestAngle]에서 멈춰
  /// 남아있게 변경(왼쪽에 쌓인 더미처럼). 장마다 jitter로 각도 흩뜨림.
  Widget _buildFlipPage(int i, double t, Rect pageRect, double k) {
    final start = _flipStart + i * _flipStagger;
    final p = _seg(t, start, start + _flipDuration);

    // 책등(x=0)까지 넓힌 박스 + 그 안에서의 책등 로컬 좌표(pivotX).
    // BentLeafPainter가 pivotX 왼쪽은 회전시키지 않고 그대로 두므로,
    // 예전에 썼던 Transform.origin 트릭 없이 이 값 하나로 충분합니다.
    final axisX = math.min(0.0, pageRect.left);
    final boxWidth = pageRect.right - axisX;
    final pivotX = -axisX;

    final double angle;
    final double bend;
    final double cornerLead;
    if (p <= 0.5) {
      // 0~90도: 실제 페이지 넘김과 같은 곡면 회전.
      angle = p * math.pi;
      final bendPhase = (p / 0.5).clamp(0.0, 1.0);
      bend = DiaryPageFlipper.maxBend * math.sin(math.pi * bendPhase);
      cornerLead = DiaryPageFlipper.maxCornerLead * (1.0 - bendPhase);
    } else {
      // 90도~정착: 곡률은 이미 0(펴짐)으로 수렴해 있고, 각도만 계속
      // 커져서 왼쪽에 눕듯 정착합니다. 장마다 restAngle을 살짝 다르게
      // 흩어서(jitter) 더미처럼 보이게 합니다.
      final settleT = ((p - 0.5) / 0.5).clamp(0.0, 1.0);
      final jitter = (i - (_flipCount - 1) / 2) * 0.02;
      final restAngle = _settleRestAngle + jitter;
      angle =
          math.pi / 2 +
          (restAngle - math.pi / 2) * Curves.easeOut.transform(settleT);
      bend = 0;
      cornerLead = 0;
    }

    final image = _leafImages[i];
    final shader = _leafShaders[i];
    final texCoords = _leafTexCoords[i];
    final indices = _leafIndices;

    final Widget leaf;
    if (image == null ||
        shader == null ||
        texCoords == null ||
        indices == null) {
      // 이미지 준비 전(초기 몇 프레임) 폴백: 단순 평면 회전.
      final tint = Color.lerp(_pageColor, Colors.white, i * 0.045)!;
      leaf = Transform(
        alignment: Alignment.centerLeft,
        origin: Offset(pivotX, 0),
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.00016)
          ..rotateY(angle),
        child: ColoredBox(color: tint),
      );
    } else {
      const cols = DiaryPageFlipper.bendColumns;
      const rows = DiaryPageFlipper.bendRows;
      final vertexCount = (cols + 1) * (rows + 1);
      leaf = CustomPaint(
        painter: BentLeafPainter(
          image: image,
          shader: shader,
          positions: Float32List(vertexCount * 2),
          texCoords: texCoords,
          colors: Int32List(vertexCount),
          indices: indices,
          angle: angle,
          bend: bend,
          cornerLead: cornerLead,
          pivotX: pivotX,
          translateX: 0,
          columns: cols,
          rows: rows,
        ),
      );
    }

    return Positioned(
      left: axisX,
      top: pageRect.top,
      width: boxWidth,
      height: pageRect.height,
      child: leaf,
    );
  }

  /// [백엔드 수정]
  /// 다 열리면 페이드아웃되던 걸, 속지들처럼 [_settleRestAngle]에서 멈춰
  /// 남아있게 변경. 튕김 없이 easeOutCubic으로 매끄럽게 회전.
  Widget _buildCover(double w, double h, double coverT) {
    final angle = Curves.easeOutCubic.transform(coverT) * _settleRestAngle;

    // [백엔드 수정]
    // 표지 힌지를 책등 밖으로 옮기는 시도 했으나 원복(책등에 그대로 붙임).
    return Positioned(
      left: 0,
      right: 4, // 오른쪽으로 속지가 살짝 보이도록 표지를 약간 짧게.
      top: 0,
      bottom: 0,
      child: Transform(
        alignment: Alignment.centerLeft,
        // [백엔드 수정]
        // 페이지 넘김과 같은 이유로 부호 반대로(아래 _buildFlipPage 참고).
        // 원근감 계수도 같은 이유로 10배 낮춤(위 _buildFlipPage 설명 참고).
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.00014)
          ..rotateY(angle),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // 가죽 느낌: 위가 살짝 밝고 아래로 갈수록 짙어지는 그라데이션.
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF6E4C39), _coverColor, Color(0xFF4A3227)],
            ),
            borderRadius: BorderRadius.circular(w * _coverRadiusRatio),
            boxShadow: [
              BoxShadow(
                color: Colors.black38,
                blurRadius: w * _coverShadowBlurRatio,
                offset: Offset(
                  w * _coverShadowOffsetXRatio,
                  h * _coverShadowOffsetYRatio,
                ),
              ),
            ],
          ),
          child: Stack(
            children: [
              // 가죽 질감(얼룩) + 박음질 라인.
              const Positioned.fill(
                child: CustomPaint(painter: _LeatherCoverPainter()),
              ),

              // 책등 쪽 접힘 하이라이트.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: w * _coverEdgeHighlightWidthRatio,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.horizontal(
                      left: Radius.circular(w * _coverRadiusRatio),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.white.withValues(alpha: 0.10),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),

              // 밴드(고무줄) 디테일.
              Positioned(
                right: w * 0.12,
                top: -h * _bandInsetRatio,
                bottom: -h * _bandInsetRatio,
                width: w * _ribbonWidthRatio,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B2A20),
                    borderRadius: BorderRadius.circular(w * _bandRadiusRatio),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: w * _bandRadiusRatio,
                        offset: Offset(w * _bandShadowOffsetXRatio, 0),
                      ),
                    ],
                  ),
                ),
              ),

              // 음각(엠보싱) 느낌의 타이틀.
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.local_activity_outlined,
                      size: w * 0.16,
                      color: const Color(0xFF48342A),
                      shadows: const [
                        Shadow(color: Color(0x33FFFFFF), offset: Offset(0, 1)),
                      ],
                    ),
                    SizedBox(height: h * _coverTitleGapRatio),
                    Text(
                      'TICKET DIARY',
                      style: TextStyle(
                        fontSize: w * 0.062,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3.5,
                        color: const Color(0xFF48342A),
                        shadows: const [
                          Shadow(
                            color: Color(0x30FFFFFF),
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 책이 착지한 직후, 주변 테이블 위로 먼지가 확 퍼졌다 가라앉는 효과.
/// [progress](0~1)에 따라 책 중심에서 사방으로 흩날리며 옅어집니다. 위치는
/// 매 프레임 고정 시드로 뽑아서(제자리에서 커지기만 하고 튀지 않음),
/// [bookW]/[bookH](책의 "책 자체" 기준 크기)에 비례하게 둬서 책이 화면에서
/// 차지하는 크기가 달라져도 먼지 퍼지는 범위가 항상 책 주변에 맞습니다.
class _DustBurstPainter extends CustomPainter {
  final double progress;
  final double bookW;
  final double bookH;

  const _DustBurstPainter({
    required this.progress,
    required this.bookW,
    required this.bookH,
  });

  // [백엔드 수정] 먼지를 더 많이 원해서 9 -> 18로 늘림.
  static const int _count = 18;
  static const Color _dustColor = Color(0xFFD9C39A);

  @override
  void paint(Canvas canvas, Size size) {
    final rng = math.Random(11);
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = bookW * 0.6;
    // 처음엔 빠르게 퍼지다(easeOut) 서서히 옅어지며 멈춥니다.
    final spread = Curves.easeOut.transform(progress);
    final fade = (1.0 - progress).clamp(0.0, 1.0);

    for (var i = 0; i < _count; i++) {
      final angle = rng.nextDouble() * math.pi * 2;
      final reach = 0.35 + rng.nextDouble() * 0.65;
      final dist = reach * maxRadius * spread;
      // [백엔드 수정]
      // 세로 오프셋 제거, 책 중심 기준 고르게 사방으로 퍼지게 수정(세로만
      // 살짝 눌러 원근감 유지).
      final pos =
          center + Offset(math.cos(angle) * dist, math.sin(angle) * dist * 0.6);
      final speckSize = (bookW * 0.012) * (0.6 + rng.nextDouble() * 0.8);
      final opacity = fade * (0.25 + rng.nextDouble() * 0.25);
      if (opacity <= 0.01) continue;
      canvas.drawCircle(
        pos,
        speckSize,
        Paint()..color = _dustColor.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DustBurstPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.bookW != bookW ||
      oldDelegate.bookH != bookH;
}

/// 방 안 테이블 위 풍경: 나무 널빤지 테이블 + 나뭇결/옹이 + 머그컵/연필/티켓
/// 조각 같은 소품 + 따뜻한 스탠드 조명과 비네트.
///
/// 스플래시 시작부터 끝까지 화면 전체를 덮어서(다이어리보다 아래 레이어)
/// 흰 배경이 절대 드러나지 않습니다.
class _RoomTablePainter extends CustomPainter {
  const _RoomTablePainter();

  @override
  void paint(Canvas canvas, Size size) {
    // 시드를 고정해 매 프레임 같은 무늬가 그려지게 합니다.
    final rng = math.Random(7);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF3A281B),
    );

    final plankH = size.height / 7;
    for (var i = 0; i < 8; i++) {
      final top = i * plankH;

      final plankColor = Color.lerp(
        const Color(0xFF4C3423),
        const Color(0xFF5D4029),
        rng.nextDouble(),
      )!;
      canvas.drawRect(
        Rect.fromLTWH(0, top, size.width, plankH - 1.4),
        Paint()..color = plankColor,
      );
      // 널빤지 사이의 어두운 이음새.
      canvas.drawRect(
        Rect.fromLTWH(0, top + plankH - 1.4, size.width, 1.4),
        Paint()..color = const Color(0xFF261709),
      );

      // 나뭇결(가로로 흐르는 얇은 곡선).
      final grainPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      final streaks = 3 + rng.nextInt(3);
      for (var s = 0; s < streaks; s++) {
        final y = top + rng.nextDouble() * plankH;
        final path = Path()..moveTo(0, y);
        var x = 0.0;
        var currentY = y;
        while (x < size.width) {
          final nextX = x + 50 + rng.nextDouble() * 90;
          final nextY = y + (rng.nextDouble() - 0.5) * 7;
          path.quadraticBezierTo(
            (x + nextX) / 2,
            currentY + (rng.nextDouble() - 0.5) * 8,
            nextX,
            nextY,
          );
          x = nextX;
          currentY = nextY;
        }
        canvas.drawPath(path, grainPaint);
      }

      // 가끔 나타나는 옹이.
      if (rng.nextDouble() < 0.45) {
        final cx = rng.nextDouble() * size.width;
        final cy = top + plankH * (0.3 + rng.nextDouble() * 0.4);
        canvas.drawOval(
          Rect.fromCenter(center: Offset(cx, cy), width: 15, height: 8),
          Paint()
            ..color = Colors.black.withValues(alpha: 0.16)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
        canvas.drawOval(
          Rect.fromCenter(center: Offset(cx, cy), width: 6, height: 3.2),
          Paint()..color = Colors.black.withValues(alpha: 0.20),
        );
      }
    }

    // ---- 테이블 위 소품들(방 안 정경) ----
    _paintMug(canvas, size);
    _paintPencil(canvas, size);
    _paintTicketStubs(canvas, size);

    // 따뜻한 스탠드 불빛이 왼쪽 위에서 비치는 느낌.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.7, -0.8),
          radius: 1.3,
          colors: [
            const Color(0xFFFFD9A0).withValues(alpha: 0.10),
            Colors.transparent,
          ],
          stops: const [0.0, 0.7],
        ).createShader(Offset.zero & size),
    );

    // 중앙이 밝고 가장자리가 어두운 조명(비네트)으로 "테이블 위" 느낌을 줍니다.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 1.15,
          colors: [
            Colors.white.withValues(alpha: 0.05),
            Colors.transparent,
            Colors.black.withValues(alpha: 0.42),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Offset.zero & size),
    );
  }

  /// 오른쪽 위, 위에서 내려다본 커피 머그컵(+받침).
  void _paintMug(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.84, size.height * 0.16);
    final r = size.shortestSide * 0.075;

    // 받침(코스터).
    canvas.drawCircle(
      center,
      r * 1.45,
      Paint()..color = const Color(0xFF2B1C10),
    );
    // 컵 몸통 그림자 + 몸통.
    canvas.drawCircle(
      center.translate(2, 3),
      r,
      Paint()..color = Colors.black.withValues(alpha: 0.35),
    );
    canvas.drawCircle(center, r, Paint()..color = const Color(0xFFEDE4D2));
    // 손잡이.
    final handleRect = Rect.fromCenter(
      center: center.translate(r * 1.25, 0),
      width: r * 0.9,
      height: r * 1.1,
    );
    canvas.drawArc(
      handleRect,
      -math.pi / 2,
      math.pi,
      false,
      Paint()
        ..color = const Color(0xFFEDE4D2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.28,
    );
    // 커피.
    canvas.drawCircle(
      center,
      r * 0.78,
      Paint()..color = const Color(0xFF3B2417),
    );
    // 커피 표면의 은은한 하이라이트.
    canvas.drawCircle(
      center.translate(-r * 0.2, -r * 0.2),
      r * 0.28,
      Paint()..color = Colors.white.withValues(alpha: 0.08),
    );
  }

  /// 왼쪽에 비스듬히 놓인 연필.
  void _paintPencil(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width * 0.13, size.height * 0.72);
    canvas.rotate(-1.15);

    final len = size.shortestSide * 0.30;
    // 원래 고정 7px 몸통 폭 기준 비율(7 / iPhone17 기준 shortestSide 402).
    final w = size.shortestSide * 0.0174;

    // 몸통(노란 육각 연필 느낌으로 위/아래 톤 분리).
    canvas.drawRect(
      Rect.fromLTWH(0, -w / 2, len, w),
      Paint()..color = const Color(0xFFD9A441),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, -w / 2, len, w / 3),
      Paint()..color = const Color(0xFFE6B95C),
    );
    // 깎인 나무 부분 + 심(폭 대비 비율은 고정 픽셀 시절과 동일하게 유지).
    final tipLen = w * (13 / 7);
    final tip = Path()
      ..moveTo(len, -w / 2)
      ..lineTo(len + tipLen, 0)
      ..lineTo(len, w / 2)
      ..close();
    canvas.drawPath(tip, Paint()..color = const Color(0xFFE8D5B5));
    final leadOffset = w * (8 / 7);
    final leadHalf = w * (1.6 / 7);
    final lead = Path()
      ..moveTo(len + leadOffset, -leadHalf)
      ..lineTo(len + tipLen, 0)
      ..lineTo(len + leadOffset, leadHalf)
      ..close();
    canvas.drawPath(lead, Paint()..color = const Color(0xFF3A3A3A));
    // 지우개 + 금속 밴드.
    canvas.drawRect(
      Rect.fromLTWH(-w * 4 / 7, -w / 2, w * 4 / 7, w),
      Paint()..color = const Color(0xFF9E9E9E),
    );
    canvas.drawRect(
      Rect.fromLTWH(-w * 11 / 7, -w / 2, w, w),
      Paint()..color = const Color(0xFFD98880),
    );

    canvas.restore();
  }

  /// 왼쪽 아래에 흩어져 있는 공연 티켓 조각들(앱 주제 디테일).
  void _paintTicketStubs(Canvas canvas, Size size) {
    void stub(Offset pos, double angle, Color color) {
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(angle);

      final w = size.shortestSide * 0.19;
      final h = w * 0.42;
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: w, height: h),
        const Radius.circular(4),
      );
      // 그림자 + 몸통.
      canvas.drawRRect(
        rect.shift(const Offset(1.5, 2.5)),
        Paint()..color = Colors.black.withValues(alpha: 0.3),
      );
      canvas.drawRRect(rect, Paint()..color = color);
      // 절취선(세로 점선).
      final dashX = w * 0.22;
      final dashPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..strokeWidth = 1;
      for (var y = -h / 2 + 3; y < h / 2 - 2; y += 4) {
        canvas.drawLine(Offset(dashX, y), Offset(dashX, y + 2), dashPaint);
      }
      // 티켓 위 글자를 암시하는 옅은 줄.
      final textPaint = Paint()
        ..color = Colors.black.withValues(alpha: 0.18)
        ..strokeWidth = 1.6;
      canvas.drawLine(
        Offset(-w * 0.32, -h * 0.16),
        Offset(dashX - 6, -h * 0.16),
        textPaint,
      );
      canvas.drawLine(
        Offset(-w * 0.32, h * 0.10),
        Offset(dashX - 14, h * 0.10),
        textPaint,
      );

      canvas.restore();
    }

    stub(
      Offset(size.width * 0.20, size.height * 0.88),
      -0.28,
      const Color(0xFFD3A39B),
    );
    stub(
      Offset(size.width * 0.33, size.height * 0.93),
      0.18,
      const Color(0xFF9CB8A7),
    );
  }

  @override
  bool shouldRepaint(covariant _RoomTablePainter oldDelegate) => false;
}

/// 가죽 표지 질감: 은은한 얼룩 + 가장자리 박음질(스티치) 라인.
class _LeatherCoverPainter extends CustomPainter {
  const _LeatherCoverPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rng = math.Random(21);

    // 가죽의 얼룩덜룩한 질감을 아주 옅은 반점으로 표현. size는 이미 책
    // 크기(w x h, 기기별로 diaryAspectRatio에 맞춰 조정됨)이므로, 반점/
    // 박음질 크기를 size 비율로 두면 어느 기기에서든 커버와 같은 비율로
    // 보입니다(예전엔 고정 픽셀이라 아이폰17 기준에서만 맞았습니다).
    final blotch = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < 46; i++) {
      final cx = rng.nextDouble() * size.width;
      final cy = rng.nextDouble() * size.height;
      final r = size.shortestSide * (0.0239 + rng.nextDouble() * 0.0877);
      blotch.color = (rng.nextBool() ? Colors.black : Colors.white).withValues(
        alpha: 0.015 + rng.nextDouble() * 0.02,
      );
      canvas.drawCircle(Offset(cx, cy), r, blotch);
    }

    // 가장자리 박음질(점선) 라인.
    final stitchPaint = Paint()
      ..color = const Color(0xFF8A6A50).withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final stitchInset = size.shortestSide * 0.0319;
    final rrect = RRect.fromRectAndRadius(
      EdgeInsets.all(stitchInset).deflateRect(Offset.zero & size),
      Radius.circular(size.shortestSide * 0.0239),
    );
    final dashLength = size.shortestSide * 0.01993;
    final dashStep = size.shortestSide * 0.03987;
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dashLength), stitchPaint);
        d += dashStep;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LeatherCoverPainter oldDelegate) => false;
}

/// 스플래시에서 표지가 열리면 드러나는, 실제 메인 화면(다이어리 인덱스
/// 페이지)의 정적 축소 복제본.
///
/// 실제 [DiaryScreen]을 직접 넣지 않는 이유: 마지막 페이드 전환 동안 스플래시와
/// 새 라우트의 [DiaryScreen]이 동시에 마운트되는데, 티켓 데이터가 static이라
/// 같은 GlobalKey들이 화면에 두 번 붙어 충돌(크래시)이 나기 때문입니다.
/// 대신 DiaryPageFrame/DiaryScreen과 같은 수치·색으로 그대로 그려서,
/// 줌이 끝나 실제 화면이 페이드인될 때 디자인이 자연스럽게 겹쳐집니다.
///
/// 확대가 끝났을 때 화면에 보이는 영역이 실제 기기 화면과 같아지도록,
/// [bookW] x [bookH](=[_SplashScreenState._buildBook]에 전달된 것과 같은
/// 크기)와 [fillScale]을 기준으로 축척(k=1/fillScale)을 계산해 실제
/// [DiaryPageFrame]과 정확히 같은 여백/비율로 배치합니다.
class _MainPageReplica extends StatelessWidget {
  final double bookW;
  final double bookH;
  final double fillScale;

  /// 스플래시 전용 종이 외곽선의 불투명도(줌 후반에 0으로 사라짐).
  final double outlineAlpha;

  const _MainPageReplica({
    required this.bookW,
    required this.bookH,
    required this.fillScale,
    required this.outlineAlpha,
  });

  static const Color _leatherColor = Color(0xFF5C4033);
  static const Color _pageColor = Color(0xFFF4F1E1);

  @override
  Widget build(BuildContext context) {
    final k = 1 / fillScale;
    return Container(
      decoration: BoxDecoration(
        color: _leatherColor,
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(5)),
        border: Border.all(
          color: Colors.black.withValues(alpha: outlineAlpha),
          width: 0.7,
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(5)),
        child: _buildMiniScreen(k, bookW, bookH),
      ),
    );
  }

  /// 실제 화면 좌표(논리 px)에 [k]를 곱해 DiaryPageFrame의 레이아웃 수치를
  /// 그대로 재현합니다. [w],[h]는 book(=bookW x bookH) 전체 크기입니다.
  Widget _buildMiniScreen(double k, double w, double h) {
    // 실제 DiaryPageFrame의 "메인 페이지" 카드(여백 +
    // DiaryPageFrame.defaultPageWidthFactor)와 정확히 같은 식
    // ([_diaryPageCardRect])을 씁니다. [_SplashScreenState._buildBook]의
    // pageRect도 같은 식을 쓰므로, 넘어가는 속지 → 이 예시 페이지 → 실제
    // 메인 페이지로 이어질 때 크기가 자연스럽게 이어집니다.
    final cardRect = _diaryPageCardRect(w, h, k);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 뒤쪽 페이지 레이어들(오른쪽에 겹쳐 보이는 종이 단들).
        for (final right in const [35.0, 38.0, 41.0, 44.0])
          Positioned(
            top: 10 * k,
            bottom: 20 * k,
            left: 30 * k,
            right: right * k,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _pageColor,
                borderRadius: BorderRadius.horizontal(
                  right: Radius.circular(15 * k),
                ),
              ),
            ),
          ),

        // 메인 페이지 종이 + 첫 페이지 내용(티켓 추가 버튼, 티켓 포켓들).
        Positioned.fromRect(
          rect: cardRect,
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: _pageColor,
              borderRadius: BorderRadius.horizontal(
                right: Radius.circular(15 * k),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 10 * k,
                  offset: Offset(5 * k, 5 * k),
                ),
              ],
            ),
            padding: EdgeInsets.symmetric(horizontal: 25 * k),
            // [임시 주석처리] 로고 없는 모습 비교용 - 원래는 아래 child:
            // Center(...)에 아이콘+"TICKET DIARY" 로고가 있었습니다.
            /*
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.local_activity_outlined,
                    size: 105 * k,
                    color: _leatherColor.withValues(alpha: 0.55),
                  ),
                  SizedBox(height: 18 * k),
                  Text(
                    'TICKET DIARY',
                    style: TextStyle(
                      fontSize: 39 * k,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4.5 * k,
                      color: _leatherColor.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
            */
          ),
        ),
      ],
    );
  }
}

/// 실제 [DiaryPageFrame]의 "메인 페이지" 카드(기본 여백
/// [DiaryPageFrame.defaultPageTop]/Bottom/Left/Right,
/// `FractionallySizedBox(widthFactor: [DiaryPageFrame.defaultPageWidthFactor])`로
/// 가로만 더 넓힘)가 [w] x [h] 크기의 프레임 안에서 차지하는 위치/크기를
/// 그대로 재현합니다. [k](=1/fillScale)는 "실제 화면 px -> 지금 프레임 기준
/// px" 환산 배율입니다. [_SplashScreenState._buildBook]의 넘어가는 속지와
/// [_MainPageReplica]의 예시 페이지가 이 식을 공유해야, 페이지 넘김 →
/// 예시 페이지 → 실제 메인 페이지로 이어질 때 크기가 끊김 없이 자연스럽게
/// 이어집니다.
///
/// [백엔드 수정]
/// 여백/widthFactor 하드코딩(옛 값 1.1) 대신 [DiaryPageFrame] 상수를 직접
/// 참조하도록 변경 - 카드 폭이 5%가량 안 맞던 문제 해결.
Rect _diaryPageCardRect(double w, double h, double k) {
  const insetTop = DiaryPageFrame.defaultPageTop;
  const insetBottom = DiaryPageFrame.defaultPageBottom;
  const insetLeft = DiaryPageFrame.defaultPageLeft;
  const insetRight = DiaryPageFrame.defaultPageRight;
  const widthFactor = DiaryPageFrame.defaultPageWidthFactor;
  final insetW = w - (insetLeft + insetRight) * k;
  final insetH = h - (insetTop + insetBottom) * k;
  return Rect.fromLTWH(
    insetLeft * k - insetW * (widthFactor - 1) / 2,
    insetTop * k,
    insetW * widthFactor,
    insetH,
  );
}

/// 바인더 링 하나(어두운 원형 그로밋 + 밝은 회색 막대). [_SplashScreenState]의
/// 펼침 애니메이션이 씁니다.
///
/// [백엔드 수정]
/// 실제 [_BinderRing](diary_page_frame.dart)과 같은 구조로 재조정 - 막대
/// 크기 고정값(20x8) 대신 [barWidth]/[barHeight] 사용, 원 지름/그림자도 통일.
Widget _buildMiniBinderRing(
  double k,
  double barWidth,
  double barHeight,
  double circleShiftX,
) {
  final circleDiameter =
      barHeight * DiaryPageFrame.binderCircleToBarHeightRatio;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      // 원(circleDiameter)이 막대 높이(barHeight)보다 크므로, Row 자체의
      // 세로 크기가 원 지름으로 커지지 않도록 SizedBox(height: barHeight)로
      // 레이아웃 높이를 고정하고, 그 안에서 OverflowBox로 원만 실제
      // 크기(circleDiameter)로 위아래로 삐져나오게 그립니다(실제
      // _BinderRing과 동일한 트릭 - 안 하면 6개 링이 원 크기만큼씩
      // 밀려 간격이 달라집니다).
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
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xFF3E2723),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
      Container(
        width: barWidth,
        height: barHeight,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(3 * k),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 5 * k,
              spreadRadius: 0.5 * k,
              offset: Offset(2 * k, 2 * k),
            ),
          ],
        ),
      ),
    ],
  );
}

/// 닫힌 다이어리에서 오른쪽으로 살짝 보이는 속지 단면(겹친 종이들) 질감.
class _PageEdgesPainter extends CustomPainter {
  const _PageEdgesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.10)
      ..strokeWidth = 0.8;
    // 오른쪽 단면: 종이가 겹겹이 쌓인 가로줄.
    for (var y = 3.0; y < size.height - 2; y += 2.4) {
      canvas.drawLine(
        Offset(size.width - 7, y),
        Offset(size.width - 1, y),
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PageEdgesPainter oldDelegate) => false;
}
