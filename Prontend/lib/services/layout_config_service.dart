import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'scrapbook_auto_layout.dart';

// [백엔드 수정]
// GET /app-config/layout-weights - 자동 배치 가중치를 앱 배포 없이 서버에서 조정.

/// 자동 배치 가중치. 앱 실행 중 한 번만 받아오고, 실패하면 기본값을 쓰고
/// 다음 호출 때 다시 시도함.
class LayoutConfigService {
  LayoutConfigService._();

  static Future<LayoutWeights>? _cached;

  static Future<LayoutWeights> weights() => _cached ??= _load();

  /// 테스트에서 네트워크 없이 가중치를 고정.
  @visibleForTesting
  static void debugSetWeights(LayoutWeights? weights) {
    _cached = weights == null ? null : Future.value(weights);
  }

  static Future<LayoutWeights> _load() async {
    try {
      final json = await ApiClient.instance.get('/app-config/layout-weights');
      return LayoutWeights.fromJson(json);
    } catch (_) {
      _cached = null;
      return const LayoutWeights();
    }
  }
}
