import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:ticketdiary/screen/diary_screen.dart';
import 'package:ticketdiary/services/app_settings_store.dart';
import 'package:ticketdiary/services/auth_service.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';

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
/// 속지는 실제 다이어리처럼 A4와 같은 세로 1:루트2(≈1:1.414) 비율입니다.
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

  /// A4 용지의 세로/가로 비율(297/210 ≈ 1.414). 속지 규격의 기준.
  static const double _a4Ratio = 297 / 210;

  static const Duration _totalDuration = Duration(milliseconds: 4000);

  // ---- 타임라인(전체 0.0~1.0 기준 구간) ----
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

  /// 4. 페이지(가운데 시선 고정)가 화면을 가득 채울 때까지 줌.
  static const double _zoomPageStart = 0.38;
  static const double _zoomPageEnd = 0.97;

  /// 촤라락이 거의 끝나는 시점에 메인 페이지 페이드인을 시작해서,
  /// 남은 줌과 페이드가 겹치며 자연스럽게 이어지도록 합니다.
  static const double _navigateAt = 0.86;

  static const Duration _fadeToMainDuration = Duration(milliseconds: 900);

  late final AnimationController _controller;

  bool _dataReady = false;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _totalDuration)
      ..addListener(_onTick)
      ..forward();
    unawaited(_loadData());
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
    if (!mounted) return;
    _dataReady = true;
    _maybeNavigate();
  }

  void _onTick() {
    if (_controller.value >= _navigateAt) _maybeNavigate();
  }

  /// 촤라락이 끝나가는 시점([_navigateAt]) 이후 + 데이터 준비 완료일 때
  /// 메인 화면을 페이드인으로 겹쳐 올립니다. 페이드가 진행되는 동안 이 화면의
  /// 남은 줌 애니메이션은 아래에서 계속 재생되므로 전환이 끊겨 보이지 않습니다.
  /// 데이터가 더 늦게 끝나면 마지막 프레임(꽉 찬 페이지)에서 대기합니다.
  void _maybeNavigate() {
    if (_navigated || !mounted) return;
    if (!_dataReady || _controller.value < _navigateAt) return;
    _navigated = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        settings: const RouteSettings(name: DiaryRoutes.diary),
        transitionDuration: _fadeToMainDuration,
        pageBuilder: (_, _, _) => const DiaryScreen(),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          child: child,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
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
          final screenW = constraints.maxWidth;
          final screenH = constraints.maxHeight;

          // 속지가 A4 비율(세로형)이 되도록 다이어리 크기를 잡습니다.
          final bookWidth = math.min(screenW * 0.52, screenH * 0.6 / _a4Ratio);
          final bookHeight = bookWidth * _a4Ratio;

          // 마지막에 오른쪽 페이지가 화면을 가득 덮는 배율.
          final fillScale =
              math.max(screenW / bookWidth, screenH / bookHeight) * 1.04;

          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => _buildScene(
              Size(screenW, screenH),
              bookWidth,
              bookHeight,
              fillScale,
              _controller.value,
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
    Size screen,
    double bookW,
    double bookH,
    double fillScale,
    double t,
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
          Center(
            child: Transform.scale(
              scale: _bookStartScale,
              child: _buildBook(bookW, bookH, t, screen),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBook(double w, double h, double t, Size screen) {
    final coverT = _seg(t, _coverStart, _coverEnd);
    final zoomPage = Curves.easeInOut.transform(
      _seg(t, _zoomPageStart, _zoomPageEnd),
    );

    // 다이어리 내부(복제본) 속 실제 "페이지 종이" 영역. 촤라락 넘어가는
    // 속지들이 이 영역과 같은 크기/위치로 넘어가도록 계산합니다.
    // (_MainPageReplica.build의 배치 계산과 동일한 식입니다.)
    final rW = w - 10.0; // 복제본 영역 폭(left 6 + right 4 제외)
    final rH = h - 10.0; // 복제본 영역 높이(top 5 + bottom 5 제외)
    final miniW = math.min(rW, rH * (screen.width / screen.height));
    final k = rH / screen.height;
    final pageRect = Rect.fromLTWH(
      6 + (rW - miniW) / 2 + 30 * k,
      5 + 10 * k,
      miniW - 75 * k, // 페이지 좌우 여백(left 30 + right 45) 제외
      rH - 30 * k, // 페이지 상하 여백(top 10 + bottom 20) 제외
    );

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
          Positioned(
            left: 6,
            right: 0,
            top: 5,
            bottom: 5,
            child: Container(
              decoration: BoxDecoration(
                color: _pageColor,
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(5),
                ),
                border: Border.all(
                  color: Colors.black.withValues(alpha: outlineAlpha),
                  width: 0.7,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 22,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: const CustomPaint(painter: _PageEdgesPainter()),
            ),
          ),

          // 갈피끈(리본). 속지 아래로 삐져나온 디테일.
          Positioned(
            right: w * 0.22,
            bottom: -13,
            child: Container(
              width: 9,
              height: 24,
              decoration: const BoxDecoration(
                color: Color(0xFFB0413E),
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(2)),
              ),
            ),
          ),

          // ---- 표지가 열린 뒤 드러나는, 다이어리 내부(줌의 목적지) ----
          // 실제 메인 화면(DiaryPageFrame + 다이어리 탭 첫 페이지)과 같은
          // 디자인의 축소 복제본. 그대로 확대되다가 진짜 메인 화면과 겹쳐집니다.
          // (오른쪽 4px는 닫혀있을 때 보이는 속지 단면을 남겨둡니다.)
          Positioned(
            left: 6,
            right: 4,
            top: 5,
            bottom: 5,
            child: _MainPageReplica(screen: screen, outlineAlpha: outlineAlpha),
          ),

          // ---- 열리는 표지가 다이어리 내부 전체에 드리우는 그림자(입체감) ----
          if (coverShadow > 0.001)
            Positioned(
              left: 6,
              right: 4,
              top: 5,
              bottom: 5,
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

          // ---- 촤라락 넘어가는 속지들(나중에 넘어갈 장이 아래) ----
          // 표지가 열리는 순간부터 다이어리 내부(메인 페이지 디자인)가 바로
          // 보이도록, 속지들은 내부의 "페이지 종이" 크기에 딱 맞춰 넘어갑니다.
          for (var i = _flipCount - 1; i >= 0; i--)
            _buildFlipPage(i, t, pageRect, k),

          // ---- 가죽 표지(왼쪽 책등을 축으로 열림) ----
          if (coverT < 1.0) _buildCover(w, h, coverT),
        ],
      ),
    );
  }

  /// 다이어리 내부의 "페이지 종이" 영역([pageRect])과 같은 크기/위치/모서리로
  /// 넘어가는 속지 한 장. 축척 [k]는 복제본과 동일한 화면 비례 계수입니다.
  Widget _buildFlipPage(int i, double t, Rect pageRect, double k) {
    final start = _flipStart + i * _flipStagger;
    final p = _seg(t, start, start + _flipDuration);
    final opacity = 1.0 - _seg(p, 0.55, 1.0);
    if (opacity <= 0.001) return const SizedBox.shrink();

    final angle = Curves.easeInOutCubic.transform(p) * math.pi * 0.62;
    // 장마다 미묘하게 톤을 다르게 해서 여러 장이 넘어가는 게 보이게 합니다.
    final tint = Color.lerp(_pageColor, Colors.white, i * 0.045)!;

    // 카메라 쪽으로 세워질수록(90도에 가까울수록) 빛을 덜 받아 어두워지고,
    // 넘어가는 중간에는 살짝 떠올라(확대) 종이가 들리는 느낌을 줍니다.
    final edgeOn = (1.0 - math.cos(angle)).clamp(0.0, 1.0);
    final lift = math.sin(p * math.pi);

    // 메인 페이지 종이와 같은 모서리(오른쪽만 둥근 15px 비례).
    final radius = BorderRadius.horizontal(right: Radius.circular(15 * k));

    return Positioned.fromRect(
      rect: pageRect,
      child: Opacity(
        opacity: opacity,
        child: Transform(
          alignment: Alignment.centerLeft,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0016)
            ..rotateY(-angle),
          child: Transform.scale(
            alignment: Alignment.centerLeft,
            scale: 1.0 + lift * 0.05,
            // 메인 페이지와 같은 순수 크림색 종이. 넘어가는 동안 책등 쪽에만
            // 살짝 그림자를 드리워 입체감을 줍니다.
            child: Container(
              decoration: BoxDecoration(
                color: tint,
                borderRadius: radius,
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.30),
                  width: 0.7,
                ),
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [Color.lerp(tint, Colors.black, 0.08)!, tint],
                  stops: const [0.0, 0.18],
                ),
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: radius,
                color: Colors.black.withValues(alpha: edgeOn * 0.22),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCover(double w, double h, double coverT) {
    // "촤라락"의 시작답게 살짝 튕기며(easeOutBack) 90도 너머까지 열립니다.
    final angle = Curves.easeOutBack.transform(coverT) * (math.pi * 0.58);
    final opacity = 1.0 - _seg(coverT, 0.55, 1.0);
    if (opacity <= 0.001) return const SizedBox.shrink();

    return Positioned(
      left: 0,
      right: 4, // 오른쪽으로 속지가 살짝 보이도록 표지를 약간 짧게.
      top: 0,
      bottom: 0,
      child: Opacity(
        opacity: opacity,
        child: Transform(
          alignment: Alignment.centerLeft,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0014)
            ..rotateY(-angle),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // 가죽 느낌: 위가 살짝 밝고 아래로 갈수록 짙어지는 그라데이션.
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF6E4C39), _coverColor, Color(0xFF4A3227)],
              ),
              borderRadius: BorderRadius.circular(7),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 18,
                  offset: Offset(2, 10),
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
                  width: 12,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(7),
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
                  top: -2,
                  bottom: -2,
                  width: 9,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF3B2A20),
                      borderRadius: BorderRadius.circular(3),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black38,
                          blurRadius: 3,
                          offset: Offset(1, 0),
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
                          Shadow(
                            color: Color(0x33FFFFFF),
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
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
      ),
    );
  }
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
    const w = 7.0;

    // 몸통(노란 육각 연필 느낌으로 위/아래 톤 분리).
    canvas.drawRect(
      Rect.fromLTWH(0, -w / 2, len, w),
      Paint()..color = const Color(0xFFD9A441),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, -w / 2, len, w / 3),
      Paint()..color = const Color(0xFFE6B95C),
    );
    // 깎인 나무 부분 + 심.
    final tip = Path()
      ..moveTo(len, -w / 2)
      ..lineTo(len + 13, 0)
      ..lineTo(len, w / 2)
      ..close();
    canvas.drawPath(tip, Paint()..color = const Color(0xFFE8D5B5));
    final lead = Path()
      ..moveTo(len + 8, -1.6)
      ..lineTo(len + 13, 0)
      ..lineTo(len + 8, 1.6)
      ..close();
    canvas.drawPath(lead, Paint()..color = const Color(0xFF3A3A3A));
    // 지우개 + 금속 밴드.
    canvas.drawRect(
      Rect.fromLTWH(-4, -w / 2, 4, w),
      Paint()..color = const Color(0xFF9E9E9E),
    );
    canvas.drawRect(
      Rect.fromLTWH(-11, -w / 2, 7, w),
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

    // 가죽의 얼룩덜룩한 질감을 아주 옅은 반점으로 표현.
    final blotch = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < 46; i++) {
      final cx = rng.nextDouble() * size.width;
      final cy = rng.nextDouble() * size.height;
      final r = 6 + rng.nextDouble() * 22;
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
    final rrect = RRect.fromRectAndRadius(
      const EdgeInsets.all(8).deflateRect(Offset.zero & size),
      const Radius.circular(6),
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 5), stitchPaint);
        d += 10;
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
/// [screen] 크기를 기준으로 축척([_MainPageReplica.build]의 k)을 계산해
/// 중앙에 화면 비율 그대로 배치합니다.
class _MainPageReplica extends StatelessWidget {
  final Size screen;

  /// 스플래시 전용 종이 외곽선의 불투명도(줌 후반에 0으로 사라짐).
  final double outlineAlpha;

  const _MainPageReplica({required this.screen, required this.outlineAlpha});

  static const Color _leatherColor = Color(0xFF5C4033);
  static const Color _pageColor = Color(0xFFF4F1E1);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final rW = constraints.maxWidth;
        final rH = constraints.maxHeight;
        // 다이어리 속지(A4 비율)의 중앙에, 실제 화면과 같은 비율의 영역을
        // 잡고 그 안에 메인 화면을 그대로 축소해 그립니다. 줌이 끝나면
        // 정확히 이 영역이 화면을 가득 채웁니다.
        final miniW = math.min(rW, rH * (screen.width / screen.height));
        final k = rH / screen.height;

        return Container(
          decoration: BoxDecoration(
            color: _leatherColor,
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(5),
            ),
            border: Border.all(
              color: Colors.black.withValues(alpha: outlineAlpha),
              width: 0.7,
            ),
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(5),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: (rW - miniW) / 2,
                  top: 0,
                  bottom: 0,
                  width: miniW,
                  child: _buildMiniScreen(k, miniW, rH),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 실제 화면 좌표(논리 px)에 [k]를 곱해 DiaryPageFrame의 레이아웃 수치를
  /// 그대로 재현합니다.
  Widget _buildMiniScreen(double k, double w, double h) {
    final pageH = h - 30 * k; // top 10 + bottom 20
    // DiaryScreen._buildPageContent의 고정 상단 여백 계산과 동일:
    // 100(버튼) + 30(간격) + 120*3(티켓) + 25*2(간격) = 540
    final topPad = ((pageH - 540 * k) / 2).clamp(20.0 * k, double.infinity);

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

        // 우측 인덱스 탭(다이어리/소식/결산/설정).
        _buildTab(k, 4, 80, const Color(0xFFE8AE75), '다이어리'),
        _buildTab(k, 7, 175, const Color(0xFF9CB8A7), '소식'),
        _buildTab(k, 10, 270, const Color(0xFFD3A39B), '결산'),
        _buildTab(k, 13, 450, const Color(0xFFB0B0B0), '설정'),

        // 메인 페이지 종이 + 첫 페이지 내용(티켓 추가 버튼, 티켓 포켓들).
        Positioned(
          top: 10 * k,
          bottom: 20 * k,
          left: 30 * k,
          right: 45 * k,
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
            child: Column(
              children: [
                SizedBox(height: topPad),
                _buildMiniAddButton(k),
                SizedBox(height: 30 * k),
                _buildMiniTicketPocket(k, '배송 전 티켓 예시'),
                SizedBox(height: 25 * k),
                _buildMiniTicketPocket(k, '공연 전 티켓 예시'),
              ],
            ),
          ),
        ),

        // 왼쪽 바인더 링.
        Positioned(
          left: -15 * k,
          top: 50 * k,
          bottom: 50 * k,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(6, (_) => _buildMiniBinderRing(k)),
          ),
        ),
      ],
    );
  }

  Widget _buildTab(
    double k,
    double right,
    double top,
    Color color,
    String text,
  ) {
    return Positioned(
      right: right * k,
      top: top * k,
      child: Container(
        width: 45 * k,
        height: 90 * k,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.horizontal(
            left: Radius.circular(10 * k),
            right: Radius.circular(5 * k),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 4 * k,
              offset: Offset(-2 * k, 2 * k),
            ),
          ],
        ),
        child: Center(
          child: RotatedBox(
            quarterTurns: 1,
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13 * k,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniAddButton(double k) {
    return Container(
      height: 100 * k,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(15 * k),
        border: Border.all(color: Colors.grey.shade400, width: 2 * k),
      ),
      child: Center(
        child: Text(
          '티켓  추가',
          style: TextStyle(
            fontSize: 26 * k,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
            letterSpacing: 4.0 * k,
          ),
        ),
      ),
    );
  }

  Widget _buildMiniTicketPocket(double k, String title) {
    return Container(
      height: 120 * k,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10 * k),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.8),
          width: 2 * k,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 10 * k,
            offset: Offset(5 * k, 5 * k),
          ),
        ],
      ),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8 * k),
        ),
        padding: EdgeInsets.all(12 * k),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12 * k,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            Expanded(
              child: Center(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 22 * k,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniBinderRing(double k) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.translate(
          offset: Offset(8 * k, 0),
          child: Container(
            width: 15 * k,
            height: 15 * k,
            decoration: const BoxDecoration(
              color: Color(0xFF3E2723),
              shape: BoxShape.circle,
            ),
          ),
        ),
        Container(
          width: 40 * k,
          height: 8 * k,
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(3 * k),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 2 * k,
                offset: Offset(1 * k, 1 * k),
              ),
            ],
          ),
        ),
      ],
    );
  }
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
