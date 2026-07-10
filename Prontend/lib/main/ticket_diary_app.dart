import 'package:flutter/material.dart';

import 'package:ticketdiary/screen/diary_screen.dart';
import 'package:ticketdiary/screen/news_screen.dart';
import 'package:ticketdiary/screen/settings_screen.dart';
import 'package:ticketdiary/screen/splash_screen.dart';
import 'package:ticketdiary/screen/summary_screen.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';

/// 앱의 루트 위젯.
///
/// - 라우팅/테마를 한 곳에서 관리합니다.
class TicketDiaryApp extends StatelessWidget {
  const TicketDiaryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ticket Diary',
      theme: ThemeData(fontFamily: 'Roboto'),
      initialRoute: DiaryRoutes.splash,
      onGenerateRoute: (settings) {
        Widget nextScreen;
        switch (settings.name) {
          case DiaryRoutes.splash:
            nextScreen = const SplashScreen();
            break;
          case DiaryRoutes.diary:
            nextScreen = const DiaryScreen();
            break;
          case DiaryRoutes.news:
            nextScreen = const NewsScreen();
            break;
          case DiaryRoutes.summary:
            nextScreen = const SummaryScreen();
            break;
          case DiaryRoutes.settings:
            nextScreen = const SettingsScreen();
            break;
          default:
            return null;
        }

        return MaterialPageRoute(
          settings: settings,
          builder: (context) => nextScreen,
        );
      },
    );
  }
}

