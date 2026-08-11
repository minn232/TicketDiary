import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'package:ticketdiary/main/ticket_diary_app.dart';

export 'package:ticketdiary/main/ticket_diary_app.dart' show TicketDiaryApp;

/// 앱 실행 엔트리포인트.
void main() async {
  // [백엔드 수정]
  // Firebase(FCM) 연동 추가로 runApp 전에 초기화 필요.
  // google-services.json등 설정 파일이 아직 없는 환경에서도 앱 자체는 뜨도록, 실패해도 무시.
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('[Firebase] 초기화 실패(무시): $e');
  }
  runApp(TicketDiaryApp());
}

