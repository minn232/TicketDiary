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
  testWidgets('물이 패널 전체를 덮은 뒤 걷힘', (tester) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const paper = Color(0xFFF4F1E1);
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 1200),
    );
    addTearDown(controller.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: ColoredBox(
              color: paper,
              child: Stack(
                children: [
                  // 패널 흉내: 제목줄 + 목록 칸
                  Column(
                    children: [
                      Container(height: 56, color: const Color(0xFFE8DFC8)),
                      for (var i = 0; i < 5; i++)
                        Container(
                          height: 64,
                          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          color: const Color(0xFFFAFAFA),
                        ),
                    ],
                  ),
                  Positioned.fill(
                    child: LiquidFlood(
                      animation: controller,
                      color: const Color(0xFF8B5E3C),
                      fillColor: paper,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    for (final v in [0.08, 0.2, 0.35, 0.5, LiquidFlood.coveredAt, 0.75, 0.9]) {
      controller.value = v;
      await tester.pump();
      await _capture(tester, key, 'flood_${(v * 100).round()}');
    }
    expect(find.byType(LiquidFlood), findsOneWidget);
  });
}
