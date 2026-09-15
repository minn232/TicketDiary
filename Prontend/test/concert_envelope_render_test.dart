import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/concert_envelope.dart';

void main() {
  testWidgets('열린 봉투는 위쪽 덮개만 펼쳐진다', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: const ColoredBox(
            color: Colors.white,
            child: Center(
              child: SizedBox(width: 150, child: ConcertEnvelope(opening: 1)),
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(ConcertEnvelope));
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage()))!;
    final data = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    for (final point in [
      Offset(rect.left - 20, rect.center.dy),
      Offset(rect.right + 20, rect.center.dy),
      Offset(rect.center.dx, rect.bottom + 20),
    ]) {
      final index = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      expect(
        (data.getUint8(index) - data.getUint8(index + 2)).abs(),
        lessThan(10),
      );
    }
    final top = Offset(rect.center.dx, rect.top - 20);
    final index = (top.dy.floor() * image.width + top.dx.floor()) * 4;
    expect(data.getUint8(index) - data.getUint8(index + 2), greaterThan(20));
    image.dispose();
  });

  Future<void> expectVisibleContent(
    WidgetTester tester,
    GlobalKey boundaryKey, {
    bool visible = true,
  }) async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage()))!;
    final data = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    var coloredPixels = 0;
    for (var i = 0; i < data.lengthInBytes; i += 4) {
      final r = data.getUint8(i);
      final g = data.getUint8(i + 1);
      final b = data.getUint8(i + 2);
      if (g > r + 40 && g > b + 20) coloredPixels++;
    }
    image.dispose();
    expect(
      coloredPixels,
      visible ? greaterThan(100) : equals(0),
      reason: '접히거나 펼쳐지는 중에도 앞면의 내용이 보여야 합니다.',
    );
  }

  testWidgets('펼친 편지의 아홉 영역 모두 실제 내용을 그린다', (tester) async {
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showConcertLetter(
                  context: context,
                  source: const Rect.fromLTWH(100, 400, 150, 100),
                  columns: [
                    for (final color in [Colors.red, Colors.green, Colors.blue])
                      RepaintBoundary(
                        child: SizedBox(
                          height: 180,
                          child: ColoredBox(color: color),
                        ),
                      ),
                  ],
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 850));
    await expectVisibleContent(tester, boundaryKey, visible: false);
    await tester.pump(const Duration(milliseconds: 600));
    await expectVisibleContent(tester, boundaryKey);
    await tester.pumpAndSettle();
    final rect = tester.getRect(
      find.byKey(const ValueKey('integrated_concert_letter')),
    );
    expect(rect.height, 180);
    final boundary =
        boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage()))!;
    final data = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        final x = (rect.left + rect.width * (col + .5) / 3).floor();
        final y = (rect.top + rect.height * (row + .5) / 3).floor();
        final index = (y * image.width + x) * 4;
        final color = [Colors.red, Colors.green, Colors.blue][col];
        expect(data.getUint8(index), (color.r * 255).round());
        expect(data.getUint8(index + 1), (color.g * 255).round());
        expect(data.getUint8(index + 2), (color.b * 255).round());
      }
    }
    image.dispose();
    await tester.tapAt(const Offset(2, 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await expectVisibleContent(tester, boundaryKey);
    await tester.pump(const Duration(milliseconds: 600));
    await expectVisibleContent(tester, boundaryKey, visible: false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
