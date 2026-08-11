import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/services/news_loading_signal.dart';
import 'package:ticketdiary/widgets/diary_route.dart';
import 'package:ticketdiary/widgets/tab_nav_coordinator.dart';

void main() {
  setUp(() {
    TabNavCoordinator.resetForTest();
    NewsLoadingSignal.isLoading.value = false;
  });

  testWidgets(
    '전환 중에 다른 탭을 요청하면, 현재 전환이 끝난 뒤 마지막 요청으로 이어서 전환한다',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();

      PageRoute<void> routeFor(DiaryTab from, DiaryTab to) {
        return MaterialPageRoute<void>(
          settings: RouteSettings(name: to.toString()),
          builder: (context) => Scaffold(body: Center(child: Text(to.toString()))),
        );
      }

      final coordinator = TabNavCoordinator.init(
        navigatorKey: navigatorKey,
        routeBuilder: routeFor,
        initialTab: DiaryTab.diary,
      );

      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('initial'))),
      ));

      coordinator.requestTab(DiaryTab.news);
      expect(coordinator.isTransitioning.value, isTrue);
      expect(coordinator.currentTab.value, DiaryTab.news);

      // 전환(진입 애니메이션)이 끝나기 전, 다른 탭을 연속으로 요청합니다.
      await tester.pump(const Duration(milliseconds: 50));
      coordinator.requestTab(DiaryTab.settings);
      // 아직 news로 가는 중이라 currentTab은 그대로고, settings는 큐에만
      // 저장됩니다 — 눌림 자체는 이 시점에 이미 "받아둔" 상태입니다.
      expect(coordinator.currentTab.value, DiaryTab.news);
      expect(coordinator.isTransitioning.value, isTrue);

      // 첫 전환 애니메이션이 완전히 끝날 때까지 진행시킵니다.
      await tester.pumpAndSettle();

      // 큐에 있던 마지막 요청(settings)이 자동으로 이어서 실행되고, 그
      // 전환도 끝까지 진행돼 안정된 상태가 됩니다.
      expect(coordinator.currentTab.value, DiaryTab.settings);
      expect(coordinator.isTransitioning.value, isFalse);
      expect(find.text(DiaryTab.settings.toString()), findsOneWidget);
    },
  );

  testWidgets(
    '전환 중인 탭을 다시 요청하면 이전에 큐에 쌓인 다른 목적지 요청은 취소된다',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();

      PageRoute<void> routeFor(DiaryTab from, DiaryTab to) {
        return MaterialPageRoute<void>(
          settings: RouteSettings(name: to.toString()),
          builder: (context) => Scaffold(body: Center(child: Text(to.toString()))),
        );
      }

      final coordinator = TabNavCoordinator.init(
        navigatorKey: navigatorKey,
        routeBuilder: routeFor,
        initialTab: DiaryTab.diary,
      );

      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('initial'))),
      ));

      coordinator.requestTab(DiaryTab.news);
      await tester.pump(const Duration(milliseconds: 50));

      // 다른 탭(settings)을 큐에 넣었다가,
      coordinator.requestTab(DiaryTab.settings);
      // 곧바로 마음을 바꿔 원래 향하던 탭(news)을 다시 요청합니다.
      coordinator.requestTab(DiaryTab.news);

      await tester.pumpAndSettle();

      // settings로는 가지 않고 news에 그대로 안정됩니다.
      expect(coordinator.currentTab.value, DiaryTab.news);
      expect(coordinator.isTransitioning.value, isFalse);
      expect(find.text(DiaryTab.news.toString()), findsOneWidget);
    },
  );

  testWidgets(
    '소식 탭 로딩이 안 끝났으면 route.animation이 끝나도 잠금이 안 풀린다',
    (tester) async {
      // 실제 버그 재현: NewsScreen이 아직 로딩 중(NewsLoadingSignal.isLoading
      // =true)인데 route.animation만 끝났다고 잠금을 풀면, 사용자가 그 사이
      // 다른 탭을 연속으로 눌렀을 때 아직 DiaryTabFlipTransition이 홀드
      // 루프로 대기 중인 화면 위에 새 전환이 겹쳐 시작돼 위젯 트리가 깨졌던
      // 문제(GlobalKey 중복 등)의 원인입니다.
      NewsLoadingSignal.isLoading.value = true;
      final navigatorKey = GlobalKey<NavigatorState>();

      PageRoute<void> routeFor(DiaryTab from, DiaryTab to) {
        return MaterialPageRoute<void>(
          settings: RouteSettings(name: to.toString()),
          builder: (context) => Scaffold(body: Center(child: Text(to.toString()))),
        );
      }

      final coordinator = TabNavCoordinator.init(
        navigatorKey: navigatorKey,
        routeBuilder: routeFor,
        initialTab: DiaryTab.diary,
      );

      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('initial'))),
      ));

      coordinator.requestTab(DiaryTab.news);
      // route.animation은 끝까지 진행시키되, NewsLoadingSignal은 아직
      // true라 잠금이 풀리면 안 됩니다.
      await tester.pumpAndSettle();
      expect(coordinator.isTransitioning.value, isTrue);

      // 이 상태에서 다른 탭을 연달아 눌러도(빠른 연속 탭) 즉시 새 전환을
      // 시작하지 않고 큐에만 쌓여야 합니다.
      coordinator.requestTab(DiaryTab.settings);
      expect(coordinator.currentTab.value, DiaryTab.news);
      expect(coordinator.isTransitioning.value, isTrue);

      // 로딩이 끝나면 그제서야 잠금이 풀리고, 큐에 쌓여있던 요청이 이어서 실행됩니다.
      NewsLoadingSignal.isLoading.value = false;
      await tester.pumpAndSettle();

      expect(coordinator.currentTab.value, DiaryTab.settings);
      expect(coordinator.isTransitioning.value, isFalse);
      expect(find.text(DiaryTab.settings.toString()), findsOneWidget);
    },
  );

  testWidgets(
    '소식 탭이 아니면 NewsLoadingSignal과 무관하게 기존처럼 바로 잠금이 풀린다',
    (tester) async {
      NewsLoadingSignal.isLoading.value = true; // 소식 탭과 무관해야 함
      final navigatorKey = GlobalKey<NavigatorState>();

      PageRoute<void> routeFor(DiaryTab from, DiaryTab to) {
        return MaterialPageRoute<void>(
          settings: RouteSettings(name: to.toString()),
          builder: (context) => Scaffold(body: Center(child: Text(to.toString()))),
        );
      }

      final coordinator = TabNavCoordinator.init(
        navigatorKey: navigatorKey,
        routeBuilder: routeFor,
        initialTab: DiaryTab.diary,
      );

      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('initial'))),
      ));

      coordinator.requestTab(DiaryTab.settings);
      await tester.pumpAndSettle();

      expect(coordinator.currentTab.value, DiaryTab.settings);
      expect(coordinator.isTransitioning.value, isFalse);
    },
  );

  testWidgets(
    '탭을 떠났다가 다시 돌아와도 예전 화면 인스턴스가 스택에 남아 GlobalKey가 충돌하지 않는다',
    (tester) async {
      // 실제 버그 재현: DiaryScreen처럼 여러 화면 인스턴스가 재사용하는
      // 고정 GlobalKey(예: TicketData.overlayKey, static이라 화면을
      // 나갔다 돌아와도 같은 인스턴스)가 있다고 할 때, pushAndRemoveUntil이
      // 예전엔 (r) => r.isFirst를 써서 스택 맨 밑 라우트(예: 스플래시
      // 직후 처음 만들어진 다이어리 화면)를 절대 제거하지 않았습니다.
      // 그 상태로 다이어리 탭에 다시 들어가면 같은 GlobalKey를 쓰는 새
      // 인스턴스가 그 위에 또 쌓여 "Duplicate GlobalKey" 예외가 났습니다.
      final sharedDiaryKey = GlobalKey();
      final navigatorKey = GlobalKey<NavigatorState>();

      PageRoute<void> routeFor(DiaryTab from, DiaryTab to) {
        return MaterialPageRoute<void>(
          settings: RouteSettings(name: to.toString()),
          builder: (context) => Scaffold(
            body: Center(
              child: to == DiaryTab.diary
                  ? KeyedSubtree(key: sharedDiaryKey, child: const Text('diary'))
                  : Text(to.toString()),
            ),
          ),
        );
      }

      final coordinator = TabNavCoordinator.init(
        navigatorKey: navigatorKey,
        routeBuilder: routeFor,
        initialTab: DiaryTab.diary,
      );

      // 스플래시가 pushReplacement로 최초 다이어리 화면을 심어두는 것과
      // 동일하게, sharedDiaryKey를 쓰는 화면을 스택의 맨 처음(바닥)에
      // 둡니다.
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          body: Center(
            child: KeyedSubtree(key: sharedDiaryKey, child: const Text('diary')),
          ),
        ),
      ));

      coordinator.requestTab(DiaryTab.news);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 다시 다이어리 탭으로 돌아옵니다 — 같은 sharedDiaryKey를 쓰는 새
      // 인스턴스가 만들어지는데, 맨 처음 인스턴스가 스택에 계속 남아있으면
      // 여기서 GlobalKey 충돌 예외가 납니다.
      coordinator.requestTab(DiaryTab.diary);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(sharedDiaryKey), findsOneWidget);
    },
  );
}
