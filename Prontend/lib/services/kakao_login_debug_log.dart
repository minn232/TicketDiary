import 'package:flutter/foundation.dart';

/// 카카오 로그인 흐름을 실기기에서 진단하기 위한 임시 로그 버퍼.
///
/// "유효하지 않은 카카오 인증 코드" 같은 오류가 정확히 어느 단계(인증 URL
/// 발급 / 웹뷰 리다이렉트 감지 / code 추출 / 백엔드 교환)에서 값이
/// 틀어지는지 화면에서 바로 확인하기 위한 용도입니다. 원인이 파악되면
/// 이 파일과 호출부를 지워도 됩니다.
class KakaoLoginDebugLog {
  KakaoLoginDebugLog._();

  static final List<String> _entries = [];

  static List<String> get entries => List.unmodifiable(_entries);

  static void add(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final entry = '[$ts] $message';
    _entries.add(entry);
    debugPrint('[KakaoDebug] $entry');
  }

  static void clear() => _entries.clear();

  /// 인가코드처럼 민감하거나 긴 값은 앞/뒤 일부만 남기고 가립니다
  /// (같은 코드가 반복 등장하는지 구분할 수 있을 정도로만).
  static String mask(String? value) {
    if (value == null) return 'null';
    if (value.isEmpty) return '(빈 문자열)';
    if (value.length <= 14) return value;
    return '${value.substring(0, 8)}...${value.substring(value.length - 4)} (len=${value.length})';
  }
}
