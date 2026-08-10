import 'package:flutter/material.dart';

import 'package:ticketdiary/screen/diary_screen.dart';
import 'package:ticketdiary/screen/news_screen.dart';
import 'package:ticketdiary/screen/settings_screen.dart';
import 'package:ticketdiary/screen/splash_screen.dart';
import 'package:ticketdiary/screen/summary_screen.dart';
import 'package:ticketdiary/widgets/diary_route.dart';
import 'package:ticketdiary/widgets/diary_tab_flip_route.dart';
import 'package:ticketdiary/widgets/tab_hit_catcher_overlay.dart';
import 'package:ticketdiary/widgets/tab_nav_coordinator.dart';

/// 앱의 루트 위젯.
///
/// - 라우팅/테마를 한 곳에서 관리합니다.
class TicketDiaryApp extends StatelessWidget {
  // TabNavCoordinator가 Navigator 밖(오버레이, MaterialApp.builder)에서도
  // 라우터를 조작할 수 있어야 해서 GlobalKey로 직접 접근합니다. 이 키는
  // 위젯이 살아있는 동안 안정적으로 유지돼야 하므로(재생성되면 안 됨)
  // const 생성자를 포기하고 필드로 한 번만 만듭니다.
  TicketDiaryApp({super.key});

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  static Widget _screenForTab(DiaryTab tab) {
    switch (tab) {
      case DiaryTab.diary:
        return const DiaryScreen();
      case DiaryTab.news:
        return const NewsScreen();
      case DiaryTab.summary:
        return const SummaryScreen();
      case DiaryTab.settings:
        return const SettingsScreen();
    }
  }

  /// 인덱스 탭 전환 라우트. 화면이 옆으로 슬라이드하는 대신, 약 1초 동안
  /// 여러 장의 속지가 넘어가는 전환([DiaryTabFlipRoute])을 씁니다 — 탭
  /// 번호(다이어리=1, 소식=2, 결산=3, 설정=4)가 커지는 이동은 앞으로,
  /// 작아지는 이동은 뒤로 넘어갑니다.
  static PageRoute<void> _tabRoute(DiaryTab from, DiaryTab to) {
    return DiaryTabFlipRoute(
      from: from,
      to: to,
      builder: (context) => _screenForTab(to),
    );
  }

  @override
  Widget build(BuildContext context) {
    // TabNavCoordinator.instance는 [TabHitCatcherOverlay]와
    // diary_tabs.dart의 buildDiarySideTabs가 함께 참조하는 전역 하나뿐인
    // 코디네이터입니다. init()은 이미 초기화됐으면 기존 인스턴스를 그대로
    // 반환하므로 build()가 여러 번 불려도 안전합니다.
    final tabNav = TabNavCoordinator.init(
      navigatorKey: _navigatorKey,
      routeBuilder: _tabRoute,
    );

    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Ticket Diary',
      theme: ThemeData(fontFamily: 'Roboto'),
      initialRoute: DiaryRoutes.splash,
      // Navigator가 그리는 화면(child) 위에, 화면 전환과 무관하게 항상
      // 같은 자리에 있는 보이지 않는 탭 히트 캐처를 겹쳐 그립니다
      // ([TabHitCatcherOverlay] 문서 참고) — 인덱스 탭을 빠르게 연속으로
      // 눌러도 전환 애니메이션 도중 눌림이 사라지지 않도록 하기 위함입니다.
      builder: (context, child) {
        return Stack(
          children: [
            ?child,
            Positioned.fill(
              child: TabHitCatcherOverlay(coordinator: tabNav),
            ),
          ],
        );
      },
      // 웹에서는 브라우저의 실제 URL(예: 루트 "/")도 Navigator가 별도
      // 라우트로 해석해 [initialRoute]와 함께 스택에 쌓아버리는 경우가
      // 있습니다(예: "/"가 DiaryRoutes.diary와 매치되어 DiaryScreen이 하나
      // 더 push됨). 그 결과 SplashScreen이 나중에 pushReplacement로
      // DiaryScreen을 넣어도 이미 쌓여있던 DiaryScreen 위에 하나가 더
      // 겹쳐 두 인스턴스가 동시에 존재하게 됩니다(예: 방금 추가한 티켓이
      // 화면엔 안 보이는데 실제로는 가려진 인스턴스에만 반영되는 문제).
      // 시작 라우트는 오직 [initialRoute] 하나여야 하므로, 브라우저 URL과
      // 무관하게 스플래시 라우트 하나만 스택에 넣도록 명시적으로 고정합니다.
      onGenerateInitialRoutes: (initialRoute) {
        return [
          MaterialPageRoute(
            settings: const RouteSettings(name: DiaryRoutes.splash),
            builder: (context) => const SplashScreen(),
          ),
        ];
      },
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case DiaryRoutes.splash:
            return MaterialPageRoute(
              settings: settings,
              builder: (context) => const SplashScreen(),
            );
          case DiaryRoutes.diary:
            return MaterialPageRoute(
              settings: settings,
              builder: (context) => _screenForTab(DiaryTab.diary),
            );
          case DiaryRoutes.news:
            return MaterialPageRoute(
              settings: settings,
              builder: (context) => _screenForTab(DiaryTab.news),
            );
          case DiaryRoutes.summary:
            return MaterialPageRoute(
              settings: settings,
              builder: (context) => _screenForTab(DiaryTab.summary),
            );
          case DiaryRoutes.settings:
            return MaterialPageRoute(
              settings: settings,
              builder: (context) => _screenForTab(DiaryTab.settings),
            );
          default:
            return null;
        }
      },
    );
  }
}

