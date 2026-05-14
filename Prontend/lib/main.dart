import 'package:flutter/material.dart';

import 'app/ticket_diary_app.dart';

export 'app/ticket_diary_app.dart' show TicketDiaryApp;

/// 앱 실행을 담당.
/// 로그인 유지나 초기 설정을 저장해서 사용하는 경우,
/// const를 제외.
void main() {
  runApp(const TicketDiaryApp());
}

