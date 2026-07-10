import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
class AuthService extends ChangeNotifier {
  AuthService._();

  static final AuthService instance = AuthService._();

  static const _storage = FlutterSecureStorage();
  static const _accessTokenKey = 'auth_access_token';
  static const _refreshTokenKey = 'auth_refresh_token';
  static const _userIdKey = 'auth_user_id';
  static const _roleKey = 'auth_role';
  static const _deviceIdKey = 'auth_device_id';

  final ApiClient _client = ApiClient.instance;

  String? _accessToken;

  // TODO(backend): 서버 스펙에 refresh_token으로 access_token을 재발급받는
  // 엔드포인트(예: POST /auth/refresh)가 아직 없습니다. 지금은 access_token이
  // 만료되면 재로그인이 필요합니다. 엔드포인트가 추가되면 [ApiClient]의 401
  // 응답을 가로채 이 값으로 재발급받도록 확장하면 됩니다.
  String? _refreshToken;
  String? _userId;
  String? _role;
  AuthUser? _currentUser;
  bool _loaded = false;

  String? get accessToken => _accessToken;

  /// 지금은 소비하는 곳이 없지만(위 TODO 참고), 재발급 엔드포인트가 생기면
  /// 바로 쓸 수 있도록 값 자체는 계속 저장/보관해둡니다.
  String? get refreshToken => _refreshToken;
  String? get userId => _userId;
  String? get role => _role;
  AuthUser? get currentUser => _currentUser;
  bool get isLoggedIn => _accessToken != null;
  bool get isGuest => _currentUser?.isGuest ?? true;

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
      // 저장소/네트워크 어느 쪽이 실패해도 로그인 안 된 상태로 계속 진행합니다.
    }
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
  /// 계정을 마이그레이션하려 하면 [AlreadyKakaoUserException]을 던집니다.
  Future<void> completeKakaoLogin(String code, {required bool migrateFromGuest}) async {
    final path = migrateFromGuest ? '/auth/migrate' : '/auth/kakao';
    try {
      final json = await _client.post(path, body: {'code': code});
      await _saveTokens(AuthTokens.fromJson(json));
      await refreshCurrentUser();
    } on ApiException catch (e) {
      if (migrateFromGuest && e.statusCode == 403) {
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

  /// 로그아웃(로컬 토큰만 제거). 다음 실행 시 [ensureSession]이 새 게스트
  /// 세션을 만듭니다.
  Future<void> logout() async {
    await _clearTokens();
    await _loginAsGuest();
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
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = identityHashCode(Object());
    return 'device_${now}_$rand';
  }
}
