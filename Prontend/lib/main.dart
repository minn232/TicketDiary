import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ticketdiary/main/ticket_diary_app.dart';

export 'package:ticketdiary/main/ticket_diary_app.dart' show TicketDiaryApp;

/// 앱 실행 엔트리포인트.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 다이어리 UI가 세로 비율 전제로 만들어져 있어(DiaryPageFrame 등),
  // 가로로 돌아가면 레이아웃이 깨집니다. 세로(정방향/뒤집힘)만 허용합니다.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]).then((_) => runApp(TicketDiaryApp()));
}

