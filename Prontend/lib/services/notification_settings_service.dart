import 'api_client.dart';

/// [백엔드 수정]
/// - `before_concert` → `day_before`/`concert_day`로 분리
/// - `show_predicted_setlist`(알림 설정과 무관하게 `/settings` 응답 최상위에
///   같이 오는 필드) 추가. "예상 셋리 노출 여부" 스위치가 이 값을 씀
///   ([AppSettingsStore] 참고).
class NotificationSettingsModel {
  final bool delivery;
  final bool dayBefore;
  final bool concertDay;
  final bool ticketing;
  final bool newConcert;

  /// 감상 메모 정리 완료 알림.
  final bool blogDraft;
  final bool showPredictedSetlist;

  const NotificationSettingsModel({
    required this.delivery,
    required this.dayBefore,
    required this.concertDay,
    required this.ticketing,
    required this.newConcert,
    required this.blogDraft,
    required this.showPredictedSetlist,
  });

  factory NotificationSettingsModel.fromJson(Map<String, dynamic> json) {
    final ns =
        json['notification_settings'] as Map<String, dynamic>? ?? const {};
    return NotificationSettingsModel(
      delivery: ns['delivery'] as bool? ?? true,
      dayBefore: ns['day_before'] as bool? ?? true,
      concertDay: ns['concert_day'] as bool? ?? true,
      ticketing: ns['ticketing'] as bool? ?? true,
      newConcert: ns['new_concert'] as bool? ?? true,
      blogDraft: ns['blog_draft'] as bool? ?? true,
      showPredictedSetlist: json['show_predicted_setlist'] as bool? ?? true,
    );
  }
}

/// 백엔드 `GET/PATCH /settings`(알림 설정 + `show_predicted_setlist`)와
/// 통신하는 서비스.
class NotificationSettingsService {
  NotificationSettingsService({ApiClient? client})
    : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  Future<NotificationSettingsModel> fetch() async {
    final json = await _client.get('/settings');
    return NotificationSettingsModel.fromJson(json);
  }

  /// [백엔드 수정]
  /// update_user_settings에서 부분 수정 가능.
  Future<NotificationSettingsModel> update({
    bool? delivery,
    bool? dayBefore,
    bool? concertDay,
    bool? ticketing,
    bool? newConcert,
    bool? blogDraft,
    bool? showPredictedSetlist,
  }) async {
    final json = await _client.patch(
      '/settings',
      body: {
        'show_predicted_setlist': ?showPredictedSetlist,
        if (delivery != null ||
            dayBefore != null ||
            concertDay != null ||
            ticketing != null ||
            newConcert != null ||
            blogDraft != null)
          'notification_settings': {
            'delivery': ?delivery,
            'day_before': ?dayBefore,
            'concert_day': ?concertDay,
            'ticketing': ?ticketing,
            'new_concert': ?newConcert,
            'blog_draft': ?blogDraft,
          },
      },
    );
    return NotificationSettingsModel.fromJson(json);
  }
}
