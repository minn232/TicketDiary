import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/nearby_peer_reveal.dart';

// NEARBY_REVEAL_FRAMES=폴더 이면 애니메이션 중간 프레임을 PNG로 저장 (움직임 눈으로 확인용)
Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final dir = Platform.environment['NEARBY_REVEAL_FRAMES'];
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
  testWidgets('윗면에서 물방울이 내려오고 카드가 펼쳐짐', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final loader = FontLoader('NanumGalmaesgeul')
        ..addFont(rootBundle.load('assets/fonts/NanumGalmaesgeul.ttf'));
      await loader.load();
    });

    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 1100),
    );
    addTearDown(controller.dispose);
    final exit = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 950),
    );
    addTearDown(exit.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'NanumGalmaesgeul'),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(top: 40),
          ),
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.45),
              child: NearbyPeerReveal(
                animation: controller,
                exit: exit,
                color: const Color(0xFF8B5E3C),
                cardColor: const Color(0xFFF4F1E1),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(radius: 44, child: Text('민')),
                    SizedBox(height: 18),
                    Text('민지님 맞나요?', style: TextStyle(fontSize: 18)),
                    SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        OutlinedButton(onPressed: null, child: Text('아니에요')),
                        SizedBox(width: 12),
                        FilledButton(
                          onPressed: null,
                          child: Text('맞아요, 연결할게요'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    for (final v in [0.12, 0.25, 0.35, 0.5, 0.7, 1.0]) {
      controller.value = v;
      await tester.pump();
      await _capture(tester, key, 'reveal_${(v * 100).round()}');
    }
    // 다 펼쳐지면 카드 내용이 보임
    expect(find.text('민지님 맞나요?'), findsOneWidget);
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(of: find.text('민지님 맞나요?'), matching: find.byType(Opacity))
          .first,
    );
    expect(opacity.opacity, 1);

    // 연결 완료 뒤 카드가 물방울로 오므라들어 화면 아래로 떨어짐
    final cardMaterial = find
        .ancestor(
          of: find.text('민지님 맞나요?'),
          matching: find.byType(DecoratedBox),
        )
        .first;
    final cardWidth = tester.getRect(cardMaterial).width;
    for (final e in [0.2, 0.42, 0.6, 0.8, 1.0]) {
      exit.value = e;
      await tester.pump();
      await _capture(tester, key, 'exit_${(e * 100).round()}');
      if (e == 0.42) {
        // 다 오므라들면 물방울 크기(지름 54)
        expect(tester.getRect(cardMaterial).width, closeTo(54, 1));
      }
    }
    expect(cardWidth, greaterThan(300));
    expect(tester.getRect(cardMaterial).top, greaterThan(844));
  });
}
