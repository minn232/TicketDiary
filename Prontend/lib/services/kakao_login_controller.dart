import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../screen/kakao_login_webview_screen.dart';
import 'auth_service.dart';
import 'kakao_login_debug_log.dart';

/// 사용자가 카카오 로그인 웹뷰를 닫거나(뒤로가기), 콜백에 code 없이
/// error 파라미터만 온 경우(카카오 쪽 로그인 취소).
class KakaoLoginCancelledException implements Exception {
  const KakaoLoginCancelledException();
}

/// `webview_flutter`가 Flutter Web을 지원하지 않아, 웹에서는 이 로그인
/// 흐름을 아예 시작할 수 없을 때 던집니다. 웹은 별도의(팝업+콜백 중계)
/// 방식이 필요합니다.
class KakaoLoginUnsupportedOnWebException implements Exception {
  const KakaoLoginUnsupportedOnWebException();
}

/// "인앱 웹뷰로 카카오 로그인 화면을 띄우고, 콜백 URL로 이동을 시도하는
/// 순간을 가로채 인가 코드를 뽑아 로그인을 완료" 하는 흐름을 담당합니다.
///
/// 카카오 개발자 콘솔에 등록된 리다이렉트 URI(`.../auth/kakao/callback`)는
/// 실제로 응답하는 백엔드 API가 아닙니다 — [KakaoLoginWebViewScreen]이
/// 그 URL로의 이동 시도 자체를 웹뷰 레벨에서 막아서 실제 요청이 나가지
/// 않게 하고, 그 자리에서 code만 꺼내 씁니다.
///
/// 이 방식은 네이티브 웹뷰(Android/iOS)가 제공하는 "이동 시도 가로채기"
/// 기능에 의존하므로, `webview_flutter`가 지원하지 않는 Flutter Web에서는
/// 동작하지 않습니다(웹은 별도 설계가 필요).
class KakaoLoginController {
  KakaoLoginController._();

  static final KakaoLoginController instance = KakaoLoginController._();

  /// 카카오 로그인 웹뷰를 열고, 인가코드를 받아 로그인/마이그레이션까지 완료합니다.
  ///
  /// [migrateFromGuest]가 true면 현재 게스트 세션을 카카오 계정으로 승격
  /// (`/auth/migrate`)하고, false면 새 카카오 로그인(`/auth/kakao`)으로
  /// 처리합니다.
  Future<void> login({
    required BuildContext context,
    required bool migrateFromGuest,
  }) async {
    KakaoLoginDebugLog.clear();
    KakaoLoginDebugLog.add('[0] login() 시작. migrateFromGuest=$migrateFromGuest');

    // 인앱 웹뷰 가로채기 방식은 네이티브(Android/iOS) 전용입니다. 웹에서
    // 그대로 진행하면 WebViewController가 플랫폼 구현체를 못 찾아 화면이
    // 먹통이 되므로, 시작 전에 명확히 막습니다.
    if (kIsWeb) {
      KakaoLoginDebugLog.add('[0] kIsWeb=true라 웹에서 중단');
      throw const KakaoLoginUnsupportedOnWebException();
    }

    final loginUrl = await AuthService.instance.fetchKakaoLoginUrl();
    if (!context.mounted) return;

    final code = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => KakaoLoginWebViewScreen(loginUrl: loginUrl),
        fullscreenDialog: true,
      ),
    );

    if (code == null || code.isEmpty) {
      KakaoLoginDebugLog.add('[4] 웹뷰가 code 없이 닫힘(취소 처리)');
      throw const KakaoLoginCancelledException();
    }

    await AuthService.instance.completeKakaoLogin(
      code,
      migrateFromGuest: migrateFromGuest,
    );
  }
}
