import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/liquid_rise.dart';

// LIQUID_RISE_FRAMES=폴더 이면 차오르는 중간 프레임을 PNG로 저장 (움직임 눈으로 확인용)
Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final dir = Platform.environment['LIQUID_RISE_FRAMES'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets('물방울이 고여 차오르고 출렁인 뒤 카드만 남음', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 1000),
    );
    addTearDown(controller.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: const Color(0xFFF4F1E1),
            child: LiquidRise(
              animation: controller,
              color: const Color(0xFF8B5E3C),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAFAFA),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  alignment: Alignment.center,
                  child: const Text('카드'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    for (final v in [0.08, 0.25, 0.45, 0.62, 0.75, 0.9, 1.0]) {
      controller.value = v;
      await tester.pump();
      await _capture(tester, key, 'liquid_${(v * 100).round()}');
    }
    // 다 차오르면 효과 없이 카드 그대로
    expect(find.byType(ClipPath), findsNothing);
    expect(find.text('카드'), findsOneWidget);
  });
}
