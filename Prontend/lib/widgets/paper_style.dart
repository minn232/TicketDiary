import 'package:flutter/material.dart';

/// 종이 다이어리 톤 공통 색. 결산 보고서(summary_report.dart)의 크림 메모지·
/// 갈색 잉크와 같은 값이라 다른 탭도 여기서 가져다 씁니다.
abstract final class PaperColors {
  /// 메모지·카드 바탕(크림)
  static const card = Color(0xFFFFFBF3);

  /// 카드 안 칸·타일(크림보다 조금 진함)
  static const tile = Color(0xFFF7EFE2);

  /// 본문 잉크(진한 갈색)
  static const ink = Color(0xFF3B2A20);

  /// 보조 글자(옅은 갈색)
  static const muted = Color(0xFF8A7765);

  /// 도장·강조(빨간 잉크)
  static const stamp = Color(0xFFC8423A);

  /// 기본 마스킹테이프(반투명 베이지) - 결산 캘린더 테이프와 같은 색
  static const tape = Color(0xFFEDE3C8);

  /// 뜻이 있을 때만 쓰는 탁한 테이프 색
  static const tapeRose = Color(0xFFC4867A);
  static const tapeMustard = Color(0xFFC9A45C);
  static const tapeSage = Color(0xFF9DAF8E);
}

/// 비스듬히 붙인 마스킹테이프 한 조각. 양 끝은 손으로 찢은 톱니 모양.
///
/// [tint]를 주면 베이지 바탕에 그 색을 살짝만 섞습니다 - 원색 그대로 쓰면
/// 크림 종이·갈색 잉크 사이에서 혼자 떠 보여서.
class MaskingTape extends StatelessWidget {
  const MaskingTape({
    super.key,
    this.tint,
    this.width = 54,
    this.height = 15,
    this.angle = -0.06,
  });

  final Color? tint;
  final double width;
  final double height;
  final double angle;

  /// 베이지에 [tint]를 섞는 비율
  static const double _tintAmount = 0.38;

  @override
  Widget build(BuildContext context) {
    final t = tint;
    final color = t == null
        ? PaperColors.tape
        : Color.lerp(PaperColors.tape, t, _tintAmount)!;
    return Transform.rotate(
      angle: angle,
      child: CustomPaint(
        size: Size(width, height),
        painter: _TapePainter(color),
      ),
    );
  }
}

class _TapePainter extends CustomPainter {
  _TapePainter(this.color);

  final Color color;

  /// 찢긴 끝의 톱니 깊이·개수
  static const double _tooth = 2.2;
  static const int _teeth = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final step = h / _teeth;
    final path = Path()..moveTo(_tooth, 0);
    path.lineTo(w - _tooth, 0);
    // 오른쪽 끝 톱니(위→아래)
    for (var i = 0; i < _teeth; i++) {
      path.lineTo(i.isEven ? w : w - _tooth * .4, step * (i + .5));
      path.lineTo(w - _tooth, step * (i + 1));
    }
    path.lineTo(_tooth, h);
    // 왼쪽 끝 톱니(아래→위)
    for (var i = _teeth - 1; i >= 0; i--) {
      path.lineTo(i.isOdd ? 0 : _tooth * .4, step * (i + .5));
      path.lineTo(_tooth, step * i);
    }
    path.close();

    canvas.drawShadow(path, Colors.black.withValues(alpha: .25), 1, false);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: .86));
  }

  @override
  bool shouldRepaint(_TapePainter old) => old.color != color;
}
