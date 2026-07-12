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
/// 쓰는 쪽이라 순환 참조가 생기기 때문입니다. 대신 401 처리는 [onUnauthorized]
/// 콜백으로 AuthService가 주입합니다.)
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

  /// 요청이 401로 실패했을 때 한 번 호출됩니다. 재발급에 성공하면 새
  /// access token을 반환하고(이 값으로 요청을 한 번 재시도합니다), 실패하면
  /// null을 반환해 원래 401을 그대로 던지게 합니다. [AuthService]가 설정합니다.
  Future<String?> Function()? onUnauthorized;

  Options get _authOptions => Options(
    headers: authToken == null ? null : {'Authorization': 'Bearer $authToken'},
  );

  Future<Map<String, dynamic>> get(String path, {bool allowAuthRetry = true}) async {
    return _send(
      () => _dio.get(path, options: _authOptions),
      _asMap,
      allowAuthRetry: allowAuthRetry,
    );
  }

  /// 응답이 JSON 객체 배열인 목록 조회용(예: `GET /tickets`).
  Future<List<dynamic>> getList(String path, {bool allowAuthRetry = true}) async {
    return _send(
      () => _dio.get(path, options: _authOptions),
      _asList,
      allowAuthRetry: allowAuthRetry,
    );
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool allowAuthRetry = true,
  }) async {
    return _send(
      () => _dio.post(path, data: body, options: _authOptions),
      _asMap,
      allowAuthRetry: allowAuthRetry,
    );
  }

  Future<Map<String, dynamic>> patch(
    String path, {
    Map<String, dynamic>? body,
    bool allowAuthRetry = true,
  }) async {
    return _send(
      () => _dio.patch(path, data: body, options: _authOptions),
      _asMap,
      allowAuthRetry: allowAuthRetry,
    );
  }

  Future<Map<String, dynamic>> delete(String path, {bool allowAuthRetry = true}) async {
    return _send(
      () => _dio.delete(path, options: _authOptions),
      _asMap,
      allowAuthRetry: allowAuthRetry,
    );
  }

  /// 이미지 등 파일을 `multipart/form-data`로 업로드합니다.
  /// (예: `POST /concerts/scan`의 `image` 필드)
  ///
  /// OCR(Vision API) + KOPIS 검색까지 서버에서 순차로 처리되어 기본 타임아웃
  /// (10초)보다 오래 걸릴 수 있으므로 이 요청만 더 넉넉한 타임아웃을 씁니다.
  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required String fileField,
    required List<int> fileBytes,
    required String filename,
    Map<String, dynamic>? fields,
    bool allowAuthRetry = true,
  }) async {
    // FormData는 한 번 전송하면 재사용할 수 없으므로(401 재시도 시 재전송 필요),
    // 요청마다 새로 만듭니다.
    FormData buildFormData() => FormData.fromMap({
      ...?fields,
      fileField: MultipartFile.fromBytes(fileBytes, filename: filename),
    });

    final options = _authOptions.copyWith(
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    );

    return _send(
      () => _dio.post(path, data: buildFormData(), options: options),
      _asMap,
      allowAuthRetry: allowAuthRetry,
    );
  }

  /// 요청을 보내고, [extract]로 응답 body를 원하는 타입으로 변환합니다.
  /// 401을 받으면 [onUnauthorized]로 재발급을 시도한 뒤 한 번만 재시도합니다.
  Future<T> _send<T>(
    Future<Response<dynamic>> Function() request,
    T Function(dynamic data) extract, {
    required bool allowAuthRetry,
  }) async {
    try {
      final response = await request();
      return extract(response.data);
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode ?? -1;
      if (statusCode == 401 && allowAuthRetry && onUnauthorized != null) {
        final newToken = await onUnauthorized!();
        if (newToken != null) {
          try {
            final retryResponse = await request();
            return extract(retryResponse.data);
          } on DioException catch (retryError) {
            throw _toApiException(retryError);
          }
        }
      }
      throw _toApiException(e);
    }
  }

  Map<String, dynamic> _asMap(dynamic data) =>
      data is Map<String, dynamic> ? data : <String, dynamic>{};

  List<dynamic> _asList(dynamic data) => data is List ? data : const [];

  ApiException _toApiException(DioException e) {
    final statusCode = e.response?.statusCode ?? -1;
    final message = _extractMessage(e.response?.data) ?? e.message ?? '알 수 없는 오류';
    return ApiException(statusCode, message);
  }

  String? _extractMessage(dynamic data) {
    if (data is Map && data['message'] is String) return data['message'] as String;
    if (data is Map && data['detail'] is String) return data['detail'] as String;
    return null;
  }
}
