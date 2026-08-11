import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/widgets/diary_tab_flip_route.dart';

/// [DiaryTabFlipTransition.holdSignal]이 true인 동안은 라우트 애니메이션이
/// 끝나도(routeT가 완료 지점에 닿아도) 목적지 화면을 바로 드러내지 않고
/// 잎이 계속 넘어가는 루프로 대기하다가, false가 되는 순간 목적지를
/// 드러내는지 검증합니다(소식 탭 로딩 스피너를 대체하는 핵심 메커니즘).
void main() {
  testWidgets('holdSignal=true면 전환이 끝나도 잎이 계속 남아 목적지를 가린다', (tester) async {
    final controller = AnimationController(
      vsync: tester,
      duration: DiaryTabFlipTransition.transitionDuration,
    );
    final holdSignal = ValueNotifier<bool>(true);
    addTearDown(controller.dispose);
    addTearDown(holdSignal.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DiaryTabFlipTransition(
          animation: controller,
          forward: true,
          holdSignal: holdSignal,
          child: const Text('news_screen_content'),
        ),
      ),
    );

    controller.value = 1.0; // 라우트 전환 자체는 완료
    await tester.pump();
    // 아직 홀드 중이라 잎이 남아 목적지를 가리고 있어야 합니다.
    expect(find.byKey(DiaryTabFlipTransition.leavesBoxKey), findsOneWidget);

    // 루프 컨트롤러가 실제로 반복 재생 중인지도 확인(시간을 흘려보내도
    // 계속 잎이 남아 있어야 함 — 완료되어 사라지면 안 됨).
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(DiaryTabFlipTransition.leavesBoxKey), findsOneWidget);

    holdSignal.value = false; // 로딩 완료
    // 리스너의 setState가 build-중-재진입을 피하려고 addPostFrameCallback
    // 으로 한 프레임 미뤄지므로, 반영되려면 pump가 한 번 더 필요합니다.
    await tester.pump();
    await tester.pump();
    expect(find.byKey(DiaryTabFlipTransition.leavesBoxKey), findsNothing);
    expect(find.text('news_screen_content'), findsOneWidget);
  });

  testWidgets('holdSignal이 null이면 기존과 동일하게 전환이 끝나면 바로 목적지를 보여준다', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: tester,
      duration: DiaryTabFlipTransition.transitionDuration,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: DiaryTabFlipTransition(
          animation: controller,
          forward: true,
          child: const Text('diary_screen_content'),
        ),
      ),
    );

    controller.value = 1.0;
    await tester.pump();
    expect(find.byKey(DiaryTabFlipTransition.leavesBoxKey), findsNothing);
    expect(find.text('diary_screen_content'), findsOneWidget);
  });

  testWidgets(
    '홀드 중에는 정적인 화면으로 대기해서, 시간이 아무리 지나도 목적지가 비치지 않는다',
    (tester) async {
      // 실제 버그 재현: 소식 탭에 데이터가 없어(빈 목록) 로딩이 금방
      // 끝나지 않는 동안, 예전엔 마지막 잎을 반복 재생(ping-pong)하는
      // 방식으로 대기했는데, 매 프레임 복잡한 곡면 메시를 다시 그리다가
      // 렌더링이 꼬여 잎과 바인더 링이 동시에 비치는 등 실제 기기에서
      // 화면이 깨지는 문제가 있었습니다("애니메이션이 끝났다가 다시
      // 시작되며 잠깐 다른 화면이 비친다"는 제보). 지금은 반복 재생 없이
      // 정지한 한 프레임으로만 대기하므로, 시간이 얼마나 지나든 잎
      // 구성(개수)이 그대로 유지돼야 합니다.
      final controller = AnimationController(
        vsync: tester,
        duration: DiaryTabFlipTransition.transitionDuration,
      );
      final holdSignal = ValueNotifier<bool>(true);
      addTearDown(controller.dispose);
      addTearDown(holdSignal.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: DiaryTabFlipTransition(
            animation: controller,
            forward: true,
            holdSignal: holdSignal,
            child: const Text('news_screen_content'),
          ),
        ),
      );

      controller.value = 1.0;
      await tester.pump();

      final leavesFinder = find.descendant(
        of: find.byKey(DiaryTabFlipTransition.leavesBoxKey),
        matching: find.byType(CustomPaint),
      );
      final initialLeafCount = tester.widgetList(leavesFinder).length;
      expect(initialLeafCount, greaterThan(0));

      // 몇 초가 지나도(반복 애니메이션이 있었다면 여러 주기가 돌 시간)
      // 잎 구성이 그대로여야 합니다 — 정지 화면이라 아예 다시 그려질
      // 이유가 없습니다.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.widgetList(leavesFinder).length,
          initialLeafCount,
          reason: 'tick $i',
        );
      }
    },
  );

  testWidgets(
    'child의 initState 도중 holdSignal이 true로 바뀌어도 build-중-setState 예외가 나지 않는다',
    (tester) async {
      // 실제 버그 재현: NewsScreen.initState()가 라우트의 첫 빌드가 아직
      // 끝나기 전에(=DiaryTabFlipTransition이 child를 막 mount하는 도중)
      // NewsLoadingSignal.isLoading.value = true를 동기적으로 실행하면서
      // "setState() or markNeedsBuild() called during build" 예외가 났던
      // 상황을 그대로 재현합니다.
      final controller = AnimationController(
        vsync: tester,
        duration: DiaryTabFlipTransition.transitionDuration,
      );
      final holdSignal = ValueNotifier<bool>(false);
      addTearDown(controller.dispose);
      addTearDown(holdSignal.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: DiaryTabFlipTransition(
            animation: controller,
            forward: true,
            holdSignal: holdSignal,
            child: _SignalFlippingChild(signal: holdSignal),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(holdSignal.value, isTrue);
    },
  );
}

/// [NewsScreen]처럼 자신의 initState에서 곧장(=아직 빌드 중인 도중)
/// holdSignal을 true로 바꾸는 자식 위젯. 위 회귀 테스트 전용.
class _SignalFlippingChild extends StatefulWidget {
  final ValueNotifier<bool> signal;

  const _SignalFlippingChild({required this.signal});

  @override
  State<_SignalFlippingChild> createState() => _SignalFlippingChildState();
}

class _SignalFlippingChildState extends State<_SignalFlippingChild> {
  @override
  void initState() {
    super.initState();
    widget.signal.value = true;
  }

  @override
  Widget build(BuildContext context) => const Text('child_content');
}
