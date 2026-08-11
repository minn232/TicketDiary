import 'api_client.dart';

/// [백엔드 수정]
/// - `before_concert` → `day_before`/`concert_day`로 분리
class NotificationSettingsModel {
  final bool delivery;
  final bool dayBefore;
  final bool concertDay;
  final bool ticketing;
  final bool newConcert;

  const NotificationSettingsModel({
    required this.delivery,
    required this.dayBefore,
    required this.concertDay,
    required this.ticketing,
    required this.newConcert,
  });

  factory NotificationSettingsModel.fromJson(Map<String, dynamic> json) {
    final ns = json['notification_settings'] as Map<String, dynamic>? ?? const {};
    return NotificationSettingsModel(
      delivery: ns['delivery'] as bool? ?? true,
      dayBefore: ns['day_before'] as bool? ?? true,
      concertDay: ns['concert_day'] as bool? ?? true,
      ticketing: ns['ticketing'] as bool? ?? true,
      newConcert: ns['new_concert'] as bool? ?? true,
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

  /// [백엔드 수정]
  /// update_user_settings에서 부분 수정 가능
  Future<NotificationSettingsModel> update({
    bool? delivery,
    bool? dayBefore,
    bool? concertDay,
    bool? ticketing,
    bool? newConcert,
  }) async {
    final json = await _client.patch(
      '/settings',
      body: {
        'notification_settings': {
          if (delivery != null) 'delivery': delivery,
          if (dayBefore != null) 'day_before': dayBefore,
          if (concertDay != null) 'concert_day': concertDay,
          if (ticketing != null) 'ticketing': ticketing,
          if (newConcert != null) 'new_concert': newConcert,
        },
      },
    );
    return NotificationSettingsModel.fromJson(json);
  }
}
