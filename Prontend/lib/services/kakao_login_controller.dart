import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth_service.dart';

/// 카카오 로그인 콜백을 받는 커스텀 스킴 딥링크.
///
/// 카카오 개발자 콘솔의 "Redirect URI"에 아래와 정확히 같은 값을 등록해야
/// 합니다: `ticketdiary://auth/kakao/callback`
/// (Android/iOS 쪽 스킴 등록은 AndroidManifest.xml / Info.plist에 이미 해둔
/// 상태이고, 서버의 `/auth/kakao/url` 응답도 이 redirect_uri로 카카오에
/// 요청되도록 백엔드에 맞춰져 있어야 합니다.)
const String kakaoRedirectUri = 'ticketdiary://auth/kakao/callback';

/// 딥링크 콜백이 제한 시간 안에 오지 않았을 때(사용자가 브라우저만 닫고
/// 돌아오지 않은 경우 등).
class KakaoLoginTimeoutException implements Exception {
  const KakaoLoginTimeoutException();
}

/// 사용자가 카카오 로그인 자체를 취소/실패한 경우.
class KakaoLoginCancelledException implements Exception {
  const KakaoLoginCancelledException();
}

/// "외부 브라우저에서 카카오 로그인 → 딥링크로 앱에 복귀" 흐름을 담당합니다.
///
/// 웹(Flutter Web)에서는 커스텀 스킴 딥링크가 동작하지 않으므로, 카카오
/// 콘솔에 배포 도메인의 실제 콜백 URL(예: `https://<도메인>/auth/kakao/callback`)을
/// 별도로 등록하고 그 경로를 앱에서 라우팅해 처리해야 합니다. 이 클래스는
/// 지금은 모바일(딥링크) 경로만 구현되어 있습니다.
class KakaoLoginController {
  KakaoLoginController._();

  static final KakaoLoginController instance = KakaoLoginController._();

  final AppLinks _appLinks = AppLinks();

  /// 카카오 로그인 URL을 외부 브라우저로 열고, 딥링크로 돌아오는 인가코드를
  /// 받아 로그인/마이그레이션까지 완료합니다.
  ///
  /// [migrateFromGuest]가 true면 현재 게스트 세션을 카카오 계정으로 승격
  /// (`/auth/migrate`)하고, false면 새 카카오 로그인(`/auth/kakao`)으로
  /// 처리합니다.
  Future<void> login({
    required bool migrateFromGuest,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final loginUrl = await AuthService.instance.fetchKakaoLoginUrl();

    final launched = await launchUrl(
      Uri.parse(loginUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!launched) throw const KakaoLoginCancelledException();

    final code = await _waitForCode(timeout);
    await AuthService.instance.completeKakaoLogin(
      code,
      migrateFromGuest: migrateFromGuest,
    );
  }

  Future<String> _waitForCode(Duration timeout) async {
    final completer = Completer<String>();
    late final StreamSubscription<Uri> sub;

    sub = _appLinks.uriLinkStream.listen((uri) {
      final code = _extractCode(uri);
      if (code == null) return;
      if (!completer.isCompleted) completer.complete(code);
      sub.cancel();
    });

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw const KakaoLoginTimeoutException(),
      );
    } finally {
      await sub.cancel();
    }
  }

  String? _extractCode(Uri uri) {
    final matchesRedirect =
        uri.scheme == 'ticketdiary' &&
        '${uri.host}${uri.path}' == 'auth/kakao/callback';
    if (!matchesRedirect) return null;
    return uri.queryParameters['code'];
  }
}
