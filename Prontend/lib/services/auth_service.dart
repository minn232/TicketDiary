import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';

/// 로그인 성공(게스트/카카오/마이그레이션) 후 서버가 내려주는 토큰 세트.
@immutable
class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final String tokenType;
  final String userId;
  final String role;

  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.userId,
    required this.role,
  });

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      userId: json['user_id'].toString(),
      role: json['role'] as String? ?? 'user',
    );
  }
}

/// `/auth/me` 응답. [isGuest]로 "카카오로 전환하기" 같은 UI 분기를 판단합니다.
@immutable
class AuthUser {
  final String id;
  final String nickname;
  final String? profileImageUrl;
  final String role;
  final bool isGuest;

  const AuthUser({
    required this.id,
    required this.nickname,
    this.profileImageUrl,
    required this.role,
    required this.isGuest,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'].toString(),
      nickname: json['nickname'] as String? ?? '',
      profileImageUrl: json['profile_image_url'] as String?,
      role: json['role'] as String? ?? 'user',
      isGuest: json['is_guest'] as bool? ?? false,
    );
  }
}

/// 이미 카카오로 가입된 계정을 다시 마이그레이션하려고 할 때(백엔드가 403을 줄 때).
class AlreadyKakaoUserException implements Exception {
  const AlreadyKakaoUserException();
}

/// 로그인/토큰/현재 계정 상태를 앱 전역에서 관리하는 싱글턴.
///
/// - 앱 최초 실행([SplashScreen])에서 저장된 토큰이 없으면 [ensureSession]이
///   자동으로 게스트 로그인을 진행합니다.
/// - 토큰은 [FlutterSecureStorage]에 저장해, 기기의 Keychain(iOS)/Keystore
///   (Android)를 통해 암호화됩니다. 웹은 브라우저 저장소 기반이라 네이티브만큼
///   강한 보안은 아니지만, 별도 패키지 의존성 없이 동일한 API로 동작합니다.
/// - [ApiClient]가 매 요청마다 [accessToken]을 읽어 Authorization 헤더에
///   실어 보내므로, 다른 서비스는 로그인 여부를 신경 쓰지 않고 API를 호출하면 됩니다.
/// - access_token이 만료되어 401이 오면 [ApiClient.onUnauthorized]를 통해
///   자동으로 `/auth/refresh`를 호출해 재발급받고 원래 요청을 재시도합니다
///   (그래도 실패하면, 즉 refresh_token까지 만료/폐기됐다면 로컬 세션을
///   정리합니다 — 다음 [ensureSession] 또는 재로그인에서 새 세션이 생깁니다).
class AuthService extends ChangeNotifier {
  AuthService._() {
    _client.onUnauthorized = _handleUnauthorized;
  }

  static final AuthService instance = AuthService._();

  static const _storage = FlutterSecureStorage();
  static const _accessTokenKey = 'auth_access_token';
  static const _refreshTokenKey = 'auth_refresh_token';
  static const _userIdKey = 'auth_user_id';
  static const _roleKey = 'auth_role';
  static const _deviceIdKey = 'auth_device_id';

  /// iOS Keychain은 앱을 지웠다 다시 설치해도 항목이 그대로 남습니다
  /// (일반 앱 데이터와 달리 삭제되지 않음). 그래서 예전에 테스트용으로
  /// 설치했던 빌드가 남긴 access/refresh token이 "새로 설치한" 앱에서도
  /// 그대로 읽혀서, 이미 만료/폐기된 토큰으로 계속 인증에 실패하는 문제가
  /// 있었습니다. [SharedPreferences](앱 삭제 시 함께 지워짐)에 "이 설치본에서
  /// 한 번이라도 실행됐는지" 표시를 남겨두고, 표시가 없으면(=재설치 이후
  /// 첫 실행) Keychain을 통째로 비운 뒤 시작합니다.
  static const _firstLaunchCleanupDoneKey = 'auth_first_launch_cleanup_done';

  final ApiClient _client = ApiClient.instance;

  String? _accessToken;

  /// access_token이 만료(401)되면 [_handleUnauthorized]가 이 값으로
  /// `/auth/refresh`를 호출해 재발급을 시도합니다.
  String? _refreshToken;
  String? _userId;
  String? _role;
  AuthUser? _currentUser;
  bool _loaded = false;

  /// 재발급 요청이 동시에 여러 번 나가지 않도록(리프레시 토큰은 1회용
  /// 회전 방식이라 동시 요청 시 하나만 성공하고 나머지는 무효화됨) 진행 중인
  /// 재발급 Future를 공유합니다.
  Future<String?>? _refreshFuture;

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  String? get userId => _userId;
  String? get role => _role;
  AuthUser? get currentUser => _currentUser;
  bool get isLoggedIn => _accessToken != null;
  bool get isGuest => _currentUser?.isGuest ?? true;

  /// "현재 로그인된 세션이 있고, 그 세션이 게스트"인 경우만 true입니다.
  ///
  /// [isGuest]는 세션이 아예 없을 때(예: [logout]이 재로그인에 실패해 토큰이
  /// 지워진 채로 멈춘 경우)도 기본값으로 true를 반환하므로, "카카오로
  /// 로그인" 버튼이 이 값만 보고 `/auth/migrate`(게스트 승격 전용, 인증
  /// 필요)로 보내면 세션이 없을 때 401이 납니다. 이 게터는 그 경우 false를
  /// 반환해, 세션이 없으면 항상 `/auth/kakao`(신규/기존 겸용)로 가도록
  /// 판단하는 데 씁니다.
  bool get hasActiveGuestSession => isLoggedIn && (_currentUser?.isGuest ?? false);

  /// 앱 시작 시 1회 호출: 저장된 토큰을 불러오고, 없으면 게스트로 로그인합니다.
  /// 스플래시 화면의 데이터 로딩 단계에서 다른 로딩과 함께 await 하면 됩니다.
  ///
  /// 백엔드가 꺼져 있거나 기기가 오프라인이어도(아직 서버 연동 전이라 흔히
  /// 있을 수 있는 상황) 이 메서드는 예외를 던지지 않습니다 — 로그인에
  /// 실패한 채로(=[isLoggedIn] false) 앱 나머지 기능은 정상적으로 뜨도록,
  /// [AppSettingsStore.load]와 같은 방식으로 실패를 조용히 흡수합니다.
  Future<void> ensureSession() async {
    if (_loaded) return;
    _loaded = true;

    await _clearKeychainOnFreshInstall();

    try {
      _accessToken = await _storage.read(key: _accessTokenKey);
      _refreshToken = await _storage.read(key: _refreshTokenKey);
      _userId = await _storage.read(key: _userIdKey);
      _role = await _storage.read(key: _roleKey);
      _client.authToken = _accessToken;

      if (_accessToken == null) {
        await _loginAsGuest();
      } else {
        // 저장된 토큰이 있어도 만료/폐기됐을 수 있으니 /auth/me로 한 번 검증합니다.
        try {
          await refreshCurrentUser();
        } catch (_) {
          await _loginAsGuest();
        }
      }
    } catch (_) {
      // 저장소 읽기 자체가 실패했을 수 있으니, 남아있을 수 있는 값을 지우고
      // 게스트 로그인을 한 번 더 시도해봅니다. 그래도 실패하면(오프라인 등)
      // 로그인 안 된 상태로 계속 진행합니다.
      try {
        await _clearTokens();
        await _loginAsGuest();
      } catch (_) {
        // 위 주석 참고: 조용히 흡수합니다.
      }
    }
  }

  /// 재설치 이후 첫 실행이면 Keychain에 남아있는 예전 토큰/device_id를
  /// 전부 지웁니다([_firstLaunchCleanupDoneKey] 참고). SharedPreferences
  /// 자체를 못 쓰는 등 판단이 실패하면, 안전하게 "지우지 않음"으로 둡니다
  /// (예전 세션이 우연히 남아있는 게, 있어야 할 로그인 자체가 막히는
  /// 것보다는 낫습니다).
  Future<void> _clearKeychainOnFreshInstall() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_firstLaunchCleanupDoneKey) ?? false) return;
      await _storage.deleteAll();
      await prefs.setBool(_firstLaunchCleanupDoneKey, true);
    } catch (_) {}
  }

  Future<void> _loginAsGuest() async {
    final deviceId = await _deviceId();
    final json = await _client.post('/auth/guest', body: {'device_id': deviceId});
    await _saveTokens(AuthTokens.fromJson(json));
    await refreshCurrentUser();
  }

  /// 카카오 로그인 URL(웹 브라우저로 열 주소)을 서버에서 받아옵니다.
  Future<String> fetchKakaoLoginUrl() async {
    final json = await _client.get('/auth/kakao/url');
    return json['url'] as String;
  }

  /// 카카오 인가코드로 로그인을 완료합니다.
  ///
  /// [migrateFromGuest]가 true면 "현재 게스트 세션을 이 카카오 계정으로
  /// 승격"([/auth/migrate])하고, false면 완전히 새로운 카카오 로그인
  /// ([/auth/kakao])으로 취급합니다. 이미 다른 사용자로 가입된 카카오
  /// 계정을 마이그레이션하려 하면(백엔드가 409로 응답) [AlreadyKakaoUserException]을
  /// 던집니다. (403은 "게스트가 아닌 유저가 마이그레이션을 시도"하는 별개의
  /// 케이스라, UI에서 마이그레이션 버튼을 게스트에게만 노출하는 한 발생하지 않습니다.)
  Future<void> completeKakaoLogin(String code, {required bool migrateFromGuest}) async {
    final path = migrateFromGuest ? '/auth/migrate' : '/auth/kakao';
    try {
      final json = await _client.post(path, body: {'code': code});
      await _saveTokens(AuthTokens.fromJson(json));
      await refreshCurrentUser();
    } on ApiException catch (e) {
      if (migrateFromGuest && e.statusCode == 409) {
        throw const AlreadyKakaoUserException();
      }
      rethrow;
    }
  }

  /// `/auth/me`를 다시 조회해 [currentUser]를 갱신합니다.
  Future<void> refreshCurrentUser() async {
    final json = await _client.get('/auth/me');
    _currentUser = AuthUser.fromJson(json);
    notifyListeners();
  }

  /// 회원 탈퇴. 성공하면 다시 게스트 세션으로 돌아갑니다.
  Future<void> deleteAccount() async {
    await _client.delete('/auth/me');
    await _clearTokens();
    await _loginAsGuest();
  }

  /// 로그아웃. 서버에 현재 refresh token 폐기를 요청한 뒤 로컬 토큰을
  /// 지우고, 가능하면 새 게스트 세션을 만듭니다.
  ///
  /// 서버 요청이 실패해도(오프라인 등) 로컬 로그아웃은 항상 진행합니다 —
  /// 사용자 입장에서 로그아웃은 실패해서는 안 되는 동작이기 때문입니다.
  ///
  /// 새 게스트 세션 생성은 실패할 수 있습니다 — 이 기기가 이미 카카오
  /// 계정으로 마이그레이션된 적이 있으면(guest_token은 그대로 남아있고
  /// role만 바뀌는 구조라) 백엔드가 게스트 로그인을 403으로 거부합니다.
  /// 이건 "게스트로 되돌아갈 수 없는" 정상적인 케이스이므로, 억지로 게스트
  /// 세션을 만들려 하지 않고 완전 로그아웃 상태(토큰 없음, currentUser
  /// 없음)로 둡니다 — [hasActiveGuestSession]이 이 상태를 false로 판단해,
  /// 다음 카카오 로그인 시도가 `/auth/migrate`가 아니라 `/auth/kakao`로
  /// 가도록 합니다.
  Future<void> logout() async {
    final currentRefreshToken = _refreshToken;
    if (currentRefreshToken != null) {
      try {
        await _client.post(
          '/auth/logout',
          body: {'refresh_token': currentRefreshToken},
          allowAuthRetry: false,
        );
      } catch (_) {
        // 위 주석 참고: 서버 실패는 무시하고 로컬 로그아웃을 계속 진행합니다.
      }
    }
    await _clearTokens();
    try {
      await _loginAsGuest();
    } catch (_) {
      // 위 doc 참고: 게스트 세션을 못 만들어도(예: 이미 카카오로 연동된
      // 기기의 403) 로그아웃 자체는 이미 끝난 상태이므로 그대로 둡니다.
    }
  }

  /// [ApiClient.onUnauthorized]로 등록되는 콜백. 저장된 refresh token으로
  /// access token 재발급을 시도합니다.
  Future<String?> _handleUnauthorized() {
    return _refreshFuture ??= _performRefresh().whenComplete(() {
      _refreshFuture = null;
    });
  }

  Future<String?> _performRefresh() async {
    final currentRefreshToken = _refreshToken;
    if (currentRefreshToken == null) {
      // refresh token이 아예 없다는 건, 세션을 한 번도 발급받지 못한
      // 상태입니다 — 보통 [ensureSession]의 최초 게스트 로그인이 앱 시작
      // 시점의 일시적인 네트워크 문제로 조용히 실패했을 때 이렇게 됩니다.
      // 그 실패는 한 번만 시도되고 끝이라(재시도 없음), 이후 인증이 필요한
      // 요청마다 계속 401("인증이 필요합니다")이 나서 앱을 재시작하기
      // 전까진 회복되지 않았습니다. 여기서 새 게스트 로그인을 한 번 더
      // 시도해, 원래 요청이 자동으로 재시도되며 스스로 복구되게 합니다.
      try {
        await _loginAsGuest();
        return _accessToken;
      } catch (_) {
        return null;
      }
    }

    try {
      final json = await _client.post(
        '/auth/refresh',
        body: {'refresh_token': currentRefreshToken},
        allowAuthRetry: false,
      );
      final tokens = AuthTokens.fromJson(json);
      await _saveTokens(tokens);
      return tokens.accessToken;
    } catch (_) {
      // refresh token도 만료/폐기된 경우: 로컬 세션을 정리합니다. 다음
      // ensureSession(앱 재시작) 또는 사용자의 재로그인에서 새 세션이 생깁니다.
      await _clearTokens();
      return null;
    }
  }

  Future<void> _saveTokens(AuthTokens tokens) async {
    _accessToken = tokens.accessToken;
    _refreshToken = tokens.refreshToken;
    _userId = tokens.userId;
    _role = tokens.role;
    _client.authToken = tokens.accessToken;

    await Future.wait([
      _storage.write(key: _accessTokenKey, value: tokens.accessToken),
      _storage.write(key: _refreshTokenKey, value: tokens.refreshToken),
      _storage.write(key: _userIdKey, value: tokens.userId),
      _storage.write(key: _roleKey, value: tokens.role),
    ]);
  }

  Future<void> _clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    _userId = null;
    _role = null;
    _currentUser = null;
    _client.authToken = null;
    await Future.wait([
      _storage.delete(key: _accessTokenKey),
      _storage.delete(key: _refreshTokenKey),
      _storage.delete(key: _userIdKey),
      _storage.delete(key: _roleKey),
    ]);
  }

  /// 게스트 로그인 식별에 쓰는 기기 고유값. 앱을 재설치하기 전까지는 같은 값을
  /// 유지하도록 secure storage에 한 번 생성해 저장해둡니다.
  Future<String> _deviceId() async {
    final existing = await _storage.read(key: _deviceIdKey);
    if (existing != null) return existing;

    final generated = _generateDeviceId();
    await _storage.write(key: _deviceIdKey, value: generated);
    return generated;
  }

  String _generateDeviceId() {
    return 'device_${const Uuid().v4()}';
  }
}
