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

  /// 이 관람일([day])에 보여줄 항목. 날짜별 티켓이 따로 열려서 안 거르면 이틀 이상 공연의
  /// 시간표가 한 목록에 섞임. `date`가 없는 항목은 어느 날이든 포함하고, 날짜가 하나뿐인
  /// 시간표는 거르지 않음(단일 날짜 시간표는 날짜 추출이 틀려도 그대로 보이게).
  /// 시간이 전부 "HH:MM"이면 시간순으로 정렬, 하나라도 비었으면 입력 순서 그대로.
  List<TimeTableEntry> entriesForDay(DateTime? day) {
    final dates = {
      for (final e in contents)
        if (e.date != null && e.date!.isNotEmpty) e.date!,
    };
    var rows = contents;
    if (day != null && dates.length >= 2) {
      final key =
          '${day.year.toString().padLeft(4, '0')}-'
          '${day.month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}';
      rows = contents
          .where((e) => e.date == null || e.date!.isEmpty || e.date == key)
          .toList();
    }
    final minutes = [for (final e in rows) _minutesOf(e.time)];
    if (minutes.isEmpty || minutes.contains(null)) return rows;
    final order = List<int>.generate(rows.length, (i) => i)
      ..sort((a, b) {
        final c = minutes[a]!.compareTo(minutes[b]!);
        return c != 0 ? c : a.compareTo(b);
      });
    return [for (final i in order) rows[i]];
  }

  static int? _minutesOf(String? time) {
    final m = RegExp(r'^\s*(\d{1,2}):(\d{2})').firstMatch(time ?? '');
    if (m == null) return null;
    return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
  }

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
