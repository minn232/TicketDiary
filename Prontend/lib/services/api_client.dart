import 'package:dio/dio.dart';

/// 서버 API 기본 주소.
///
/// 지금은 로컬 개발 백엔드를 가리키는 자리표시자입니다. 실제 배포 전에는
/// `--dart-define=API_BASE_URL=https://...`로 빌드하거나, 이 기본값 자체를
/// 실제 서버 주소로 바꿔주세요.
const String _defaultApiBaseUrl = 'http://localhost:8000';

const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: _defaultApiBaseUrl,
);

/// 서버가 2xx 이외의 상태 코드를 응답했을 때 던지는 예외.
class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// 백엔드와 통신하는 얇은 HTTP 클라이언트.
///
/// [authToken]을 설정해두면 이후 모든 요청에 `Authorization` 헤더가 자동으로
/// 실립니다. [AuthService]가 로그인/로그아웃 시점마다 이 값을 갱신합니다.
/// (여기서 AuthService를 직접 참조하지 않는 이유: AuthService가 이 클래스를
/// 쓰는 쪽이라 순환 참조가 생기기 때문입니다.)
class ApiClient {
  ApiClient._()
    : _dio = Dio(
        BaseOptions(
          baseUrl: apiBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

  static final ApiClient instance = ApiClient._();

  final Dio _dio;

  /// 현재 로그인된 사용자의 access token. null이면 인증 헤더 없이 요청합니다.
  String? authToken;

  Options get _authOptions => Options(
    headers: authToken == null ? null : {'Authorization': 'Bearer $authToken'},
  );

  Future<Map<String, dynamic>> get(String path) async {
    return _unwrap(() => _dio.get(path, options: _authOptions));
  }

  Future<Map<String, dynamic>> post(String path, {Map<String, dynamic>? body}) async {
    return _unwrap(() => _dio.post(path, data: body, options: _authOptions));
  }

  Future<Map<String, dynamic>> delete(String path) async {
    return _unwrap(() => _dio.delete(path, options: _authOptions));
  }

  Future<Map<String, dynamic>> _unwrap(
    Future<Response<dynamic>> Function() request,
  ) async {
    try {
      final response = await request();
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      return <String, dynamic>{};
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode ?? -1;
      final message = _extractMessage(e.response?.data) ?? e.message ?? '알 수 없는 오류';
      throw ApiException(statusCode, message);
    }
  }

  String? _extractMessage(dynamic data) {
    if (data is Map && data['message'] is String) return data['message'] as String;
    if (data is Map && data['detail'] is String) return data['detail'] as String;
    return null;
  }
}
