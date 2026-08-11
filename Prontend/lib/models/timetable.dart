import 'package:flutter/foundation.dart';

// [백엔드 수정]
// time/description(둘 다 non-null) → date/time/stage(전부 nullable)/event(필수)로 스키마 변경.
/// 타임테이블 한 항목. 백엔드 `schemas/timetable.py`의 `TimeTableEntry`와 대응.
@immutable
class TimeTableEntry {
  final String? date;
  final String? time;
  final String? stage;
  final String event;

  const TimeTableEntry({this.date, this.time, this.stage, required this.event});

  factory TimeTableEntry.fromJson(Map<String, dynamic> json) {
    return TimeTableEntry(
      date: json['date'] as String?,
      time: json['time'] as String?,
      stage: json['stage'] as String?,
      event: json['event'] as String,
    );
  }
}

/// `GET /concerts/{concertId}/timetable` 응답. 백엔드 `TimeTableResponse`와 대응.
@immutable
class TimeTableResponse {
  final String id;
  final String concertId;
  final List<TimeTableEntry> contents;

  const TimeTableResponse({
    required this.id,
    required this.concertId,
    required this.contents,
  });

  factory TimeTableResponse.fromJson(Map<String, dynamic> json) {
    return TimeTableResponse(
      id: json['id'] as String,
      concertId: json['concert_id'] as String,
      contents: (json['contents'] as List<dynamic>? ?? const [])
          .map((e) => TimeTableEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
