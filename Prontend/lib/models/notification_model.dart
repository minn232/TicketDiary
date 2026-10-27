import 'package:flutter/foundation.dart';

// [백엔드 수정]
// 인앱 알림함(GET/PATCH/DELETE /notifications) 신규 연동.
/// 알림함 한 항목. 백엔드 `schemas/notification.py`의 `NotificationResponse`와 대응.
@immutable
class NotificationModel {
  final String id;
  final String? ticketId;
  final String type;
  final String title;
  final String body;
  final bool isRead;
  final DateTime scheduledAt;
  // [백엔드 수정] 눌렀을 때 이동할 공연과 썸네일 - 목록 응답에만 채워짐.
  final String? concertId;
  final String? posterUrl;

  const NotificationModel({
    required this.id,
    this.ticketId,
    required this.type,
    required this.title,
    required this.body,
    required this.isRead,
    required this.scheduledAt,
    this.concertId,
    this.posterUrl,
  });

  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    return NotificationModel(
      id: json['id'] as String,
      ticketId: json['ticket_id'] as String?,
      type: json['type'] as String,
      title: json['title'] as String,
      body: json['body'] as String,
      isRead: json['is_read'] as bool,
      scheduledAt: DateTime.parse(json['scheduled_at'] as String),
      concertId: json['concert_id'] as String?,
      posterUrl: json['poster_url'] as String?,
    );
  }
}
