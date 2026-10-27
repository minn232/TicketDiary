import 'package:flutter/material.dart';

// [백엔드 수정] 알림함 표시 규칙 - 종류별 라벨/아이콘/색, 상대 시간, 날짜 묶음.

/// 알림 종류별 표시(제목 자리에 들어가는 라벨과 태그 아이콘·색).
class NotificationKind {
  final String label;
  final IconData icon;
  final Color color;

  /// 눌렀을 때 다이어리의 그 티켓으로 가는 알림(공연 전날/당일/배송). 아니면 소식 탭의 공연으로.
  final bool opensTicket;

  const NotificationKind(
    this.label,
    this.icon,
    this.color, {
    this.opensTicket = false,
  });

  static const _kinds = {
    // 오늘/내일은 받은 날 기준이라 며칠 뒤 알림함에서 헷갈려서 공연 기준 이름으로.
    'day_before': NotificationKind(
      '공연 전날',
      Icons.event_rounded,
      Color(0xFF8B5E3C),
      opensTicket: true,
    ),
    'concert_day': NotificationKind(
      '공연 당일',
      Icons.music_note_rounded,
      Color(0xFFE0455E),
      opensTicket: true,
    ),
    'delivery_day': NotificationKind(
      '티켓 배송',
      Icons.local_shipping_outlined,
      Color(0xFF4A7BB7),
      opensTicket: true,
    ),
    'ticketing_day': NotificationKind(
      '티켓팅 오픈',
      Icons.confirmation_number_outlined,
      Color(0xFF3DA866),
    ),
    'new_concert': NotificationKind(
      '새 공연 소식',
      Icons.campaign_outlined,
      Color(0xFF7A5CE0),
    ),
  };

  static const _fallback = NotificationKind(
    '알림',
    Icons.notifications_none_rounded,
    Color(0xFF8A8A8A),
  );

  static NotificationKind of(String type) => _kinds[type] ?? _fallback;
}

String _two(int v) => v.toString().padLeft(2, '0');

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// 카드에 붙는 상대 시간 - "방금", "5분 전", "3시간 전", "어제 09:00", "4일 전", 그 이전은 날짜.
String notificationTimeLabel(DateTime at, DateTime now) {
  final local = at.toLocal();
  final diff = now.difference(local);
  final days = _day(now).difference(_day(local)).inDays;
  if (diff.inMinutes < 1) return '방금';
  if (days == 0) {
    return diff.inMinutes < 60 ? '${diff.inMinutes}분 전' : '${diff.inHours}시간 전';
  }
  if (days == 1) return '어제 ${_two(local.hour)}:${_two(local.minute)}';
  if (days < 7) return '$days일 전';
  if (local.year == now.year) return '${local.month}월 ${local.day}일';
  return '${local.year}.${_two(local.month)}.${_two(local.day)}';
}

const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

/// 알림함에 보여줄 본문 - 본문의 "오늘/내일"은 보낸 날 기준이라, 오늘 받은 게 아니면 실제 날짜로
/// 바꿈("내일 공연이에요." → "10월 29일(수) 공연이에요."). 푸시 문구(서버 본문)는 그대로 둠.
String notificationInboxBody(
  String type,
  String body,
  DateTime scheduledAt,
  DateTime now,
) {
  final sent = _day(scheduledAt.toLocal());
  if (sent == _day(now)) return body;
  final match = RegExp(r'^(오늘|내일) ?').firstMatch(body);
  const datedTypes = {'day_before', 'concert_day', 'ticketing_day'};
  if (match == null || !datedTypes.contains(type)) return body;
  final target = match.group(1) == '내일'
      ? DateTime(sent.year, sent.month, sent.day + 1)
      : sent;
  final date =
      '${target.month}월 ${target.day}일(${_weekdays[target.weekday - 1]})';
  return '$date ${body.substring(match.end)}';
}

/// 목록 묶음 제목 - 오늘 / 어제 / 이번 주(최근 7일) / 이전.
String notificationGroupLabel(DateTime at, DateTime now) {
  final days = _day(now).difference(_day(at.toLocal())).inDays;
  if (days <= 0) return '오늘';
  if (days == 1) return '어제';
  if (days < 7) return '이번 주';
  return '이전';
}
