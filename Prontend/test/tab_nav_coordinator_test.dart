import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/widgets/diary_route.dart';
import 'package:ticketdiary/widgets/tab_nav_coordinator.dart';

void main() {
  setUp(() {
    TabNavCoordinator.resetForTest();
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
}
