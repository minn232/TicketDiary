import 'package:flutter/foundation.dart';

// [백엔드 수정]
// 전역 오프라인 신호 신규 - connectivity_plus 없이 [ApiClient] 요청 성패로
// 판단(서버 응답 자체를 못 받으면 오프라인, 4xx/5xx는 온라인으로 취급).
class ConnectivityStatus {
  ConnectivityStatus._();
  static final ConnectivityStatus instance = ConnectivityStatus._();

  final ValueNotifier<bool> isOffline = ValueNotifier(false);
}
