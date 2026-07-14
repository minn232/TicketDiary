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

