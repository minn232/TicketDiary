import 'package:flutter/foundation.dart';

/// 타임테이블 한 항목. 백엔드 `schemas/timetable.py`의 `TimeTableEntry`와 대응.
@immutable
class TimeTableEntry {
  final String time;
  final String description;

  const TimeTableEntry({required this.time, required this.description});

  factory TimeTableEntry.fromJson(Map<String, dynamic> json) {
    return TimeTableEntry(
      time: json['time'] as String,
      description: json['description'] as String,
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
