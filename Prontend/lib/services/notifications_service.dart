import '../models/notification_model.dart';
import 'api_client.dart';

// [백엔드 수정]
// 인앱 알림함 3개 엔드포인트(app/api/v1/endpoints/notifications.py)에 대응하는 서비스.
/// 알림함 서비스(`/notifications`).
class NotificationsService {
  NotificationsService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  /// 알림 목록 조회(`GET /notifications`).
  Future<List<NotificationModel>> list() async {
    final list = await _client.getList('/notifications');
    return [
      for (final item in list)
        NotificationModel.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// 읽음 처리(`PATCH /notifications/{id}/read`).
  Future<void> markRead(String id) async {
    await _client.patch('/notifications/$id/read');
  }

  /// 삭제(`DELETE /notifications/{id}`).
  Future<void> delete(String id) async {
    await _client.delete('/notifications/$id');
  }
}
