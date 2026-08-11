import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ticketdiary/main/ticket_diary_app.dart';

export 'package:ticketdiary/main/ticket_diary_app.dart' show TicketDiaryApp;

/// 앱 실행 엔트리포인트.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // [백엔드 수정]
  // Firebase(FCM) 연동 추가로 runApp 전에 초기화 필요.
  // google-services.json등 설정 파일이 아직 없는 환경에서도 앱 자체는 뜨도록, 실패해도 무시.
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('[Firebase] 초기화 실패(무시): $e');
  }

  // 다이어리 UI가 세로 비율 전제로 만들어져 있어(DiaryPageFrame 등),
  // 가로로 돌아가면 레이아웃이 깨집니다. 세로(정방향/뒤집힘)만 허용합니다.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(TicketDiaryApp());
}

