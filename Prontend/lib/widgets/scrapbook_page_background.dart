import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Decorative paper only; never participates in the scrapbook gestures.
class ScrapbookPageBackground extends StatelessWidget {
  const ScrapbookPageBackground({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(painter: _PaperPainter(), size: Size.infinite),
    ),
  );
}

class _PaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final paint = Paint();
    canvas.drawRect(bounds, paint..color = const Color(0xFFF1EBDD));
    canvas.drawRect(
      bounds,
      paint
        ..shader = const LinearGradient(
          colors: [Color(0xFFD1C2A6), Color(0xFFF5F0E4), Color(0xFFE9DFCB)],
          stops: [0, 0.12, 1],
        ).createShader(bounds),
    );
    paint.shader = null;
    // Fixed seed keeps the fine paper fibres stable across repaints.
    final random = math.Random(73);
    for (var i = 0; i < 2200; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      canvas.drawLine(
        Offset(x, y),
        Offset(x + random.nextDouble() * 1.8 + 0.3, y + 0.4),
        paint
          ..color = const Color(0xFF786448).withValues(alpha: 0.045)
          ..strokeWidth = 0.5,
      );
    }
    // Dark cloth binding and layered page edges, inspired by a physical journal.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, 7, size.height),
      paint..color = const Color(0xFF38352D),
    );
    canvas.drawRect(
      Rect.fromLTWH(7, 0, 3, size.height),
      paint..color = const Color(0xFF99896D),
    );
    for (var i = 0; i < 3; i++) {
      final x = size.width - 3.0 - i * 2.5;
      canvas.drawLine(
        Offset(x, 8),
        Offset(x, size.height - 8),
        paint
          ..color = const Color(0xFFB7A78D)
          ..strokeWidth = 0.6,
      );
    }
    for (double y = 15; y < size.height - 12; y += 9) {
      canvas.drawLine(
        Offset(13, y),
        Offset(13, y + 3),
        paint
          ..color = const Color(0xFF9A8869).withValues(alpha: 0.4)
          ..strokeWidth = 0.7,
      );
    }
    // Quiet ruled-paper details stay behind the existing movable notes.
    for (double y = 48; y < size.height - 28; y += 24) {
      canvas.drawLine(
        Offset(23, y),
        Offset(size.width - 16, y),
        paint
          ..color = const Color(0xFF8A967F).withValues(alpha: 0.09)
          ..strokeWidth = 0.5,
      );
    }
    _stamp(canvas, Offset(size.width - 31, 40), paint);
    _sprig(canvas, Offset(size.width - 24, size.height - 38), paint);
    final label = TextPainter(
      text: const TextSpan(
        text: 'TICKET DIARY  /  MEMORIES',
        style: TextStyle(
          fontSize: 7,
          letterSpacing: 2,
          color: Color(0xFF9A8B73),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(0, size.width - 48));
    label.paint(canvas, Offset(24, size.height - 18));
  }

  void _stamp(Canvas canvas, Offset center, Paint paint) {
    paint
      ..color = const Color(0xFF985E4C).withValues(alpha: 0.24)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawCircle(center, 18, paint);
    canvas.drawCircle(center, 15, paint);
    for (var i = 0; i < 3; i++) {
      canvas.drawLine(
        center + Offset(-48, 6.0 + i * 4),
        center + Offset(-8, -3.0 + i * 4),
        paint,
      );
    }
    paint.style = PaintingStyle.fill;
  }

  void _sprig(Canvas canvas, Offset base, Paint paint) {
    canvas.save();
    canvas.translate(base.dx, base.dy);
    canvas.rotate(-0.3);
    paint
      ..color = const Color(0xFF73806A).withValues(alpha: 0.32)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..quadraticBezierTo(-12, -35, -3, -77),
      paint,
    );
    paint.style = PaintingStyle.fill;
    for (var i = 0; i < 5; i++) {
      final y = -12.0 - i * 12;
      final direction = i.isEven ? -1.0 : 1.0;
      canvas.drawPath(
        Path()
          ..moveTo(-5, y)
          ..quadraticBezierTo(
            -5 + direction * 23,
            y - 5,
            -5 + direction * 16,
            y - 18,
          )
          ..quadraticBezierTo(-5 + direction * 3, y - 16, -5, y),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PaperPainter oldDelegate) => false;
}
