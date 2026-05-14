import 'package:flutter/material.dart';

import '../diary_screen.dart';
import '../news_screen.dart';
import '../settings_screen.dart';
import '../summary_screen.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/page_transitions.dart';

/// 앱의 루트 위젯.
///
/// - 라우팅/테마/전환 애니메이션/옵저버를 한 곳에서 관리합니다.
class TicketDiaryApp extends StatelessWidget {
  const TicketDiaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ticket Diary',
      theme: ThemeData(
        fontFamily: 'Roboto',
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: DiaryPageTransitionsBuilder(),
            TargetPlatform.iOS: DiaryPageTransitionsBuilder(),
            TargetPlatform.macOS: DiaryPageTransitionsBuilder(),
            TargetPlatform.windows: DiaryPageTransitionsBuilder(),
            TargetPlatform.linux: DiaryPageTransitionsBuilder(),
            TargetPlatform.fuchsia: DiaryPageTransitionsBuilder(),
          },
        ),
      ),
      navigatorObservers: [DiaryNavigatorObserver()],
      initialRoute: DiaryRoutes.diary,
      routes: {
        DiaryRoutes.diary: (context) => const DiaryScreen(),
        DiaryRoutes.news: (context) => const NewsScreen(),
        DiaryRoutes.summary: (context) => const SummaryScreen(),
        DiaryRoutes.settings: (context) => const SettingsScreen(),
      },
    );
  }
}

