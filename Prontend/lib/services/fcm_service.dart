import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

// [백엔드 수정]
/// FCM(푸시 알림) 토큰 등록 + 수신 처리.
/// 모바일(안드로이드)에서만 동작.
/// ios는 추후 설정 필요.
class FcmService {
  FcmService._();
  static final FcmService instance = FcmService._();

  bool _initialized = false;

  /// 앱 시작 시 한 번 호출(splash_screen.dart의 데이터 로딩 참고).
  /// 권한 요청 → 토큰 발급 → 서버 등록(`PATCH /settings/fcm-token`) → 토큰
  /// 갱신 구독까지 한 번에 처리하며, 실패해도(권한 거부/기기 미지원/설정
  /// 파일 누락 등) 앱 시작을 막지 않도록 전부 조용히 무시.
  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();

      final token = await messaging.getToken();
      if (token != null) await _registerToken(token);

      messaging.onTokenRefresh.listen(_registerToken);

      // 포그라운드(앱 사용 중) 수신 시 시스템 알림처럼 배너를 띄우려면
      // flutter_local_notifications 같은 별도 패키지가 필요한데, 이번
      // 범위 밖이라 일단 로그만 남깁니다.
      FirebaseMessaging.onMessage.listen((message) {
        debugPrint('[FCM] foreground message: ${message.notification?.title}');
      });
    } catch (e) {
      debugPrint('[FCM] init 실패(무시): $e');
    }
  }

  Future<void> _registerToken(String token) async {
    try {
      await ApiClient.instance.patch(
        '/settings/fcm-token',
        body: {'fcm_token': token},
      );
    } catch (e) {
      debugPrint('[FCM] 토큰 등록 실패(무시): $e');
    }
  }
}
