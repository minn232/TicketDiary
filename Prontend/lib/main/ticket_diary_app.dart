import 'package:flutter/material.dart';

import 'package:ticketdiary/screen/diary_screen.dart';
import 'package:ticketdiary/screen/news_screen.dart';
import 'package:ticketdiary/screen/settings_screen.dart';
import 'package:ticketdiary/screen/summary_screen.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';

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
      theme: ThemeData(fontFamily: 'Roboto'),
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
