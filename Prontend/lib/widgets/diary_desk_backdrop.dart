import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'diary_page_frame.dart';

// [백엔드 수정]
// 스플래시의 책상(RoomTablePainter)·가죽 표지(LeatherCoverPainter)를 메인
// 화면 다이어리 바깥에도 깔려고 splash_screen.dart에서 옮겨옴.

/// 다이어리 프레임 뒤 배경: 스플래시와 같은 책상 + 프레임 자리의 가죽 표지.
/// 프레임 위치는 [DiaryPageFrame.build]와 같은 식으로 계산합니다.
class DiaryDeskBackdrop extends StatelessWidget {
  final bool useSafeArea;

  /// 가로모드 2페이지 스프레드가 가능한 화면인지([DiaryPageFrame.landscapeCompanionPanel]).
  final bool twoPageCapable;

  /// false면 책상 없이 표지만(스플래시 미리보기 - 책상은 스플래시가 그림).
  final bool showDesk;
  final double topReserve;
  final double aspectRatio;

  const DiaryDeskBackdrop({
    super.key,
    this.useSafeArea = true,
    this.twoPageCapable = true,
    this.showDesk = true,
    this.topReserve = DiaryPageFrame.indexTabTopReserve,
    this.aspectRatio = DiaryPageFrame.diaryAspectRatio,
  });

  // [백엔드 수정]
  // 스플래시 끝 장면과 책상 무늬(이음새·틈)가 같도록, 스플래시의 책 크기·줌
  // 식을 여기서 공유. 스플래시 장면은 화면 가운데 기준으로 책상을
  // splashFillScale / splashBookStartScale배 확대한 채 끝남.
  static const double splashBookSizeBoost = 1.2;
  static const double splashBookStartScale = 0.34;

  static double splashBookWidth({
    required double screenW,
    required double screenHForBook,
  }) {
    return splashBookSizeBoost *
        math.min(
          screenW * 0.52,
          screenHForBook * 0.6 * DiaryPageFrame.diaryAspectRatio,
        );
  }

  /// 마지막에 페이지가 실제 다이어리 화면과 같은 크기가 되는 배율.
  /// DiaryPageFrame처럼 "안에 맞추기(contain)"라 min.
  static double splashFillScale({
    required double screenW,
    required double screenHForBook,
  }) {
    final bookWidth = splashBookWidth(
      screenW: screenW,
      screenHForBook: screenHForBook,
    );
    final bookHeight = bookWidth / DiaryPageFrame.diaryAspectRatio;
    return math.min(screenW / bookWidth, screenHForBook / bookHeight);
  }

  /// 화면 전체([size])에 그린 책상을 가운데 기준으로 확대할 배율 - 스플래시
  /// 마지막 프레임의 sceneScale과 같음([padding]은 SafeArea 여백).
  static double splashEndDeskScale(Size size, EdgeInsets padding) {
    final screenW = size.width - padding.horizontal;
    final screenH = size.height - padding.vertical;
    if (screenW <= 0 || screenH <= 0) return 1.0;
    final usesTwoPage =
        DiaryPageFrame.resolveTwoPageLayout(pageHeight: screenH).spreadWidth <=
        screenW;
    final topReserve = usesTwoPage ? 0.0 : DiaryPageFrame.indexTabTopReserve;
    final fillScale = splashFillScale(
      screenW: screenW,
      screenHForBook: screenH - topReserve,
    );
    return fillScale / splashBookStartScale;
  }

  // [백엔드 수정]
  // 스플래시 갈피끈(리본)을 메인에도 같은 자리에 두려고 공유. 표지 뒤에
  // 그려서 표지 아래로 삐져나온 부분만 보임. 비율은 책(=프레임) 폭/높이 기준.
  static const double ribbonRightRatio = 0.22;
  static const double ribbonProtrudeRatio = 0.02946; // 13 / 441.3
  static const double ribbonWidthRatio = 0.03588; // 9 / 250.85
  static const double ribbonHeightRatio = 0.05439; // 24 / 441.3
  static const double ribbonRadiusRatio = 0.00797; // 2 / 250.85

  /// 책(프레임) [w] x [h] 기준 Stack에 넣는 갈피끈.
  static Widget buildRibbon(double w, double h) {
    return Positioned(
      right: w * ribbonRightRatio,
      bottom: -h * ribbonProtrudeRatio,
      child: Container(
        width: w * ribbonWidthRatio,
        height: h * ribbonHeightRatio,
        decoration: BoxDecoration(
          color: const Color(0xFFB0413E),
          borderRadius: BorderRadius.vertical(
            bottom: Radius.circular(w * ribbonRadiusRatio),
          ),
        ),
      ),
    );
  }

  Rect _coverRect(double availableWidth, double availableHeight) {
    if (twoPageCapable && availableHeight.isFinite) {
      final layout = DiaryPageFrame.resolveTwoPageLayout(
        pageHeight: availableHeight,
        aspectRatio: aspectRatio,
      );
      if (layout.spreadWidth <= availableWidth) {
        return Rect.fromLTWH(
          (availableWidth - layout.spreadWidth) / 2,
          0,
          layout.spreadWidth,
          availableHeight,
        );
      }
    }
    final reservedHeight = availableHeight - topReserve;
    double frameWidth;
    double frameHeight;
    if (availableWidth / reservedHeight > aspectRatio) {
      frameHeight = reservedHeight;
      frameWidth = frameHeight * aspectRatio;
    } else {
      frameWidth = availableWidth;
      frameHeight = frameWidth / aspectRatio;
    }
    // 바인더 링 구멍(원)이 프레임 왼쪽 밖으로 나가서 표지를 그만큼 왼쪽으로 넓힘.
    final ring = DiaryPageFrame.computeRingMetrics(
      frameWidth: frameWidth,
      frameHeight: frameHeight,
    );
    final leftExtra = math.max(0.0, -(ring.binderLeft + ring.circleShiftX)) + 8;
    final frameLeft = math.max(0.0, (availableWidth - frameWidth) / 2);
    return Rect.fromLTWH(
      frameLeft - leftExtra,
      topReserve + math.max(0.0, (reservedHeight - frameHeight) / 2),
      frameWidth + leftExtra,
      frameHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cover = LayoutBuilder(
      builder: (context, constraints) {
        final rect = _coverRect(constraints.maxWidth, constraints.maxHeight);
        // 2페이지 모드도 장식 크기는 페이지 한 장(오른쪽 페이지) 기준.
        final bookW = rect.height * aspectRatio;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (showDesk)
              Positioned(
                left: rect.right - bookW,
                top: rect.top,
                width: bookW,
                height: rect.height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [buildRibbon(bookW, rect.height)],
                ),
              ),
            Positioned.fromRect(
              rect: rect,
              child: DiaryLeatherCover(
                // 2페이지 모드도 장식 크기는 페이지 한 장 폭 기준.
                bookWidth: rect.height * aspectRatio,
                bookHeight: rect.height,
              ),
            ),
          ],
        );
      },
    );
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showDesk)
            LayoutBuilder(
              builder: (context, constraints) => ClipRect(
                child: Transform.scale(
                  scale: splashEndDeskScale(
                    constraints.biggest,
                    MediaQuery.paddingOf(context),
                  ),
                  child: const CustomPaint(
                    painter: RoomTablePainter(showProps: false),
                    child: SizedBox.expand(),
                  ),
                ),
              ),
            ),
          useSafeArea
              ? SafeArea(maintainBottomViewPadding: true, child: cover)
              : cover,
        ],
      ),
    );
  }
}

/// 스플래시 표지와 같은 가죽 표지(그라데이션 + 얼룩·박음질 + 책등 하이라이트 + 그림자).
/// [children]은 표지 위 장식(스플래시의 밴드·타이틀).
class DiaryLeatherCover extends StatelessWidget {
  final double bookWidth;
  final double bookHeight;
  final List<Widget> children;

  const DiaryLeatherCover({
    super.key,
    required this.bookWidth,
    required this.bookHeight,
    this.children = const [],
  });

  static const Color coverColor = Color(0xFF5C4033);

  // 원래 고정 px / 아이폰17 기준 책 크기(250.85 x 441.3).
  static const double _radiusRatio = 0.0279;
  static const double _shadowBlurRatio = 0.07176;
  static const double _shadowOffsetXRatio = 0.00797;
  static const double _shadowOffsetYRatio = 0.02266;
  static const double _edgeHighlightWidthRatio = 0.04784;

  @override
  Widget build(BuildContext context) {
    final w = bookWidth;
    final h = bookHeight;
    return DecoratedBox(
      decoration: BoxDecoration(
        // 가죽 느낌: 위가 살짝 밝고 아래로 갈수록 짙어지는 그라데이션.
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6E4C39), coverColor, Color(0xFF4A3227)],
        ),
        borderRadius: BorderRadius.circular(w * _radiusRatio),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.266),
            blurRadius: w * _shadowBlurRatio,
            offset: Offset(w * _shadowOffsetXRatio, h * _shadowOffsetYRatio),
          ),
        ],
      ),
      child: Stack(
        children: [
          // 가죽 질감(얼룩) + 박음질 라인.
          const Positioned.fill(
            child: CustomPaint(painter: LeatherCoverPainter()),
          ),

          // 책등 쪽 접힘 하이라이트.
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: w * _edgeHighlightWidthRatio,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(w * _radiusRatio),
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
          ...children,
        ],
      ),
    );
  }
}

/// 방 안 테이블 위 풍경: 나무 널빤지 테이블 + 나뭇결/옹이 + 머그컵/연필/티켓
/// 조각 같은 소품 + 따뜻한 스탠드 조명과 비네트.
///
/// 스플래시 시작부터 끝까지 화면 전체를 덮어서(다이어리보다 아래 레이어)
/// 흰 배경이 절대 드러나지 않습니다.
class RoomTablePainter extends CustomPainter {
  // [백엔드 수정] 메인 화면은 머그컵이 우측 탭 뒤로 삐져나와 소품 끔.
  final bool showProps;

  const RoomTablePainter({this.showProps = true});

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
    if (showProps) {
      _paintMug(canvas, size);
      _paintPencil(canvas, size);
      _paintTicketStubs(canvas, size);
    }

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
  bool shouldRepaint(covariant RoomTablePainter oldDelegate) =>
      oldDelegate.showProps != showProps;
}

/// 가죽 표지 질감: 은은한 얼룩 + 가장자리 박음질(스티치) 라인.
class LeatherCoverPainter extends CustomPainter {
  const LeatherCoverPainter();

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
  bool shouldRepaint(covariant LeatherCoverPainter oldDelegate) => false;
}
