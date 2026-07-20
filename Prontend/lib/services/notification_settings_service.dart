import 'api_client.dart';

/// 백엔드 `notification_settings`(delivery/before_concert)와 대응.
///
/// "하루전 알림"과 "당일날 알림"은 UI상으로는 별개 스위치지만, 백엔드에는
/// 이 둘을 합친 `before_concert` 플래그 하나만 있어서 항상 같은 값으로
/// 취급됩니다.
class NotificationSettingsModel {
  final bool delivery;
  final bool beforeConcert;

  const NotificationSettingsModel({
    required this.delivery,
    required this.beforeConcert,
  });

  factory NotificationSettingsModel.fromJson(Map<String, dynamic> json) {
    final ns = json['notification_settings'] as Map<String, dynamic>? ?? const {};
    return NotificationSettingsModel(
      delivery: ns['delivery'] as bool? ?? true,
      beforeConcert: ns['before_concert'] as bool? ?? true,
    );
  }
}

/// 백엔드 `GET/PATCH /settings` 중 알림 설정 부분과 통신하는 서비스.
class NotificationSettingsService {
  NotificationSettingsService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  Future<NotificationSettingsModel> fetch() async {
    final json = await _client.get('/settings');
    return NotificationSettingsModel.fromJson(json);
  }

  /// 백엔드가 `notification_settings`를 부분 수정이 아니라 통째로 덮어쓰기
  /// 때문에(스키마 기본값이 둘 다 true), 하나만 바꾸더라도 항상 두 값을
  /// 함께 보내야 다른 값이 의도치 않게 초기화되는 걸 막을 수 있습니다.
  Future<NotificationSettingsModel> update({
    required bool delivery,
    required bool beforeConcert,
  }) async {
    final json = await _client.patch(
      '/settings',
      body: {
        'notification_settings': {
          'delivery': delivery,
          'before_concert': beforeConcert,
        },
      },
    );
    return NotificationSettingsModel.fromJson(json);
  }
}
