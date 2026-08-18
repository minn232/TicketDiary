import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/widgets/carousel_slide_transition.dart';
import 'package:ticketdiary/widgets/news_pull_tab.dart';

/// 소식 페이지 풀탭 전환을 구성하는 두 위젯을 네트워크 없이 순수하게
/// 검증합니다(NewsScreen 전체는 소식 API의 Dio 타임아웃 타이머가 가짜 시간
/// 환경에서 정리되지 않아 통합 테스트에 부적합하므로, 실제 상태머신 전환은
/// 시뮬레이터에서 확인합니다).
void main() {
  void pinDeviceSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('풀탭 조각은 slide 0에서 왼쪽, 1에서 오른쪽으로 이동한다', (tester) async {
    pinDeviceSize(tester);
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(controller.dispose);

    var tapCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: NewsPullTabOverlay(
                  slide: controller,
                  onTap: () => tapCount++,
                  pageTop: 40,
                  heartWipe: const AlwaysStoppedAnimation<double>(0.0),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final heart = find.byIcon(Icons.favorite);
    expect(heart, findsOneWidget);

    controller.value = 0.0;
    await tester.pump();
    final leftX = tester.getTopLeft(heart).dx;

    controller.value = 1.0;
    await tester.pump();
    final rightX = tester.getTopLeft(heart).dx;

    // slide가 커지면 풀탭이 오른쪽으로 확실히 이동한다.
    expect(rightX, greaterThan(leftX + 50));

    // 풀탭을 누르면 콜백이 호출된다.
    await tester.tap(heart);
    expect(tapCount, 1);
  });

  testWidgets('풀탭 조각의 화살표는 왼쪽(0)에선 오른쪽, 오른쪽(1)에선 왼쪽을 가리킨다',
      (tester) async {
    pinDeviceSize(tester);
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: NewsPullTabOverlay(
                  slide: controller,
                  onTap: () {},
                  pageTop: 40,
                  heartWipe: const AlwaysStoppedAnimation<double>(0.0),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    controller.value = 0.0;
    await tester.pump();
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);

    controller.value = 1.0;
    await tester.pump();
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('캐러셀 전환: 정방향은 from이 오른쪽으로, to가 왼쪽에서 들어온다', (tester) async {
    Future<Offset> offsetAt(double progress, {required bool reverse}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 200,
              child: CarouselSlideTransition(
                from: const Text('FROM'),
                to: const Text('TO'),
                progress: progress,
                reverse: reverse,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getTopLeft(find.text('FROM'));
    }

    // 두 자식 모두 항상 트리에 존재(밀어내기라 동시에 보임) + 렌더 예외 없음.
    await offsetAt(0.5, reverse: false);
    expect(find.text('FROM'), findsOneWidget);
    expect(find.text('TO'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 정방향: progress가 커질수록 from(소식)이 오른쪽으로 이동한다.
    final f0 = await offsetAt(0.0, reverse: false);
    final f1 = await offsetAt(1.0, reverse: false);
    expect(f1.dx, greaterThan(f0.dx));

    // 역방향: progress가 커질수록 from(찜)이 왼쪽으로 이동한다.
    final r0 = await offsetAt(0.0, reverse: true);
    final r1 = await offsetAt(1.0, reverse: true);
    expect(r1.dx, lessThan(r0.dx));
  });

  testWidgets('로딩 중 하트 쐐기 애니메이션은 값 전체 구간에서 예외 없이 그려지고, 0/1에서 하트가 트리에 남아있다',
      (tester) async {
    pinDeviceSize(tester);
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 300),
    );
    final heartWipe = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(controller.dispose);
    addTearDown(heartWipe.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: NewsPullTabOverlay(
                  slide: controller,
                  onTap: () {},
                  pageTop: 40,
                  heartWipe: heartWipe,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 사라짐(0~0.5)과 나타남(0.5~1) 양쪽 구간, 그리고 "완전히 채워진"
    // 양 끝(0, 1)을 모두 훑어도 렌더 예외가 없어야 합니다.
    for (final p in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      heartWipe.value = p;
      await tester.pump();
      expect(tester.takeException(), isNull);
      // ClipPath로 시각적으로만 잘릴 뿐, 하트 아이콘 위젯 자체는 항상
      // 트리에 남아 있습니다(0/1일 땐 클립 없이 온전히 보임).
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    }
  });
}
