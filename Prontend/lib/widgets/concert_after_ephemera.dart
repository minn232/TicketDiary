import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'hanji_texture.dart';

/// 배경 종이 위에 붙이는 작은 인쇄 장식. 터치 이벤트는 받지 않는다.
class ConcertAfterEphemera extends StatelessWidget {
  final HSVColor base;
  const ConcertAfterEphemera({super.key, required this.base});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;
      Widget piece(int kind, double x, double y, double width, double ratio) {
        final pw = math.min(w * width, h * .28 * ratio);
        final ph = pw / ratio;
        return Positioned(
          left: (w - pw) * x,
          top: (h - ph) * y,
          width: pw,
          height: ph,
          child: Opacity(
            opacity: .8,
            child: RepaintBoundary(
              child: CustomPaint(painter: _EphemeraPainter(kind, base)),
            ),
          ),
        );
      }

      return IgnorePointer(
        child: Stack(
          children: [
            piece(0, .08, .54, .43, 2.25),
            piece(1, .91, .94, .29, .93),
            piece(2, .91, .44, .18, .42),
          ],
        ),
      );
    },
  );
}

class _EphemeraPainter extends CustomPainter {
  final int kind;
  final HSVColor base;
  const _EphemeraPainter(this.kind, this.base);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paper = base.toColor();
    final ink = HSVColor.fromAHSV(
      .8,
      base.hue,
      (base.saturation * .25 + .12).clamp(.12, .38),
      .37,
    ).toColor();
    canvas.save();
    canvas.scale(
      size.width / 200,
      size.height /
          (kind == 0
              ? 89
              : kind == 1
              ? 215
              : 476),
    );
    final bounds = Rect.fromLTWH(
      0,
      0,
      200,
      kind == 0
          ? 89
          : kind == 1
          ? 215
          : 476,
    );
    final outline = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7;
    void label(
      String text,
      double x,
      double y,
      double fontSize, {
      bool bold = false,
    }) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: ink,
            fontFamily: 'Georgia',
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            letterSpacing: .8,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 195 - x);
      tp.paint(canvas, Offset(x, y));
      tp.dispose();
    }

    Path shape;
    if (kind == 2) {
      shape = Path()
        ..moveTo(32, 421)
        ..cubicTo(2, 300, 31, 104, 169, 12)
        ..cubicTo(197, 145, 150, 304, 32, 421)
        ..close();
    } else {
      shape = Path()..addRect(bounds.deflate(2));
      if (kind == 0) {
        for (final x in [2.0, 198.0]) {
          shape = Path.combine(
            PathOperation.difference,
            shape,
            Path()
              ..addOval(Rect.fromCircle(center: Offset(x, 44.5), radius: 9)),
          );
        }
      }
    }
    canvas.drawShadow(shape, Colors.black.withValues(alpha: .15), 1.5, false);
    canvas.drawPath(shape, Paint()..color = paper);
    canvas.save();
    canvas.clipPath(shape);
    HanjiTexturePainter(seed: 91 + kind).paint(canvas, bounds.size);
    canvas.restore();
    if (kind == 0) {
      canvas.drawRect(bounds.deflate(7), outline);
      for (double y = 10; y < 80; y += 5) {
        canvas.drawLine(Offset(150, y), Offset(150, y + 2), outline);
      }
      label('LIVE PERFORMANCE', 15, 14, 8);
      label('ADMIT ONE', 15, 30, 17, bold: true);
      label('KEEP THIS MEMORY', 15, 58, 7);
      label('No. 001', 155, 16, 6);
      for (var i = 0; i < 14; i++) {
        canvas.drawRect(
          Rect.fromLTWH(157 + i * 2.2, 34, i % 3 == 0 ? 1.6 : .7, 27),
          Paint()..color = ink,
        );
      }
    } else if (kind == 1) {
      // 월/요일 배치를 임의의 공연 날짜로 오인하지 않도록 만년 캘린더로 표기한다.
      label('PERPETUAL', 15, 14, 9);
      label('CALENDAR', 15, 29, 17, bold: true);
      label('JAN FEB MAR APR MAY JUN', 15, 59, 6.5);
      label('JUL AUG SEP OCT NOV DEC', 15, 73, 6.5);
      canvas.drawLine(const Offset(15, 91), const Offset(184, 91), outline);
      for (var day = 1; day <= 31; day++) {
        final col = (day - 1) % 7;
        final row = (day - 1) ~/ 7;
        label(day.toString().padLeft(2, '0'), 16 + col * 24, 101 + row * 18, 9);
      }
      label('DAYS TO REMEMBER', 15, 195, 7);
    } else {
      canvas.save();
      canvas.clipPath(shape);
      for (var i = 0; i < 28; i++) {
        final y = 65.0 + i * 12;
        final x = 175 - y * .32;
        canvas.drawPath(
          Path()
            ..moveTo(x, y)
            ..quadraticBezierTo(x - 44, y - 34, x - 92, y - 37),
          outline,
        );
        canvas.drawPath(
          Path()
            ..moveTo(x, y)
            ..quadraticBezierTo(x + 33, y - 8, x + 65, y - 45),
          outline,
        );
      }
      canvas.restore();
      canvas.drawPath(
        Path()
          ..moveTo(17, 465)
          ..quadraticBezierTo(64, 280, 169, 20),
        outline..strokeWidth = 2,
      );
      canvas.drawPath(
        Path()
          ..moveTo(17, 465)
          ..lineTo(32, 435)
          ..lineTo(24, 433)
          ..close(),
        Paint()..color = ink,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EphemeraPainter oldDelegate) =>
      kind != oldDelegate.kind || base != oldDelegate.base;
}
