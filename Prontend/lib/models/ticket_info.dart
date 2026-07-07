import 'package:flutter/foundation.dart';

/// 공연 타임테이블의 한 항목(시간/라벨).
@immutable
class TimetableEntry {
  final String time;
  final String label;

  const TimetableEntry({required this.time, required this.label});
}

/// 티켓 스캔으로 추출된 정보를 담는 모델.
///
/// 기본 5개 필드(공연명/공연장/날짜/가격/좌석) 외의 정보는 [extraFields]에
/// 자유롭게 추가할 수 있어, 나중에 OCR/백엔드가 더 많은 필드를 추출하게 되어도
/// 이 모델과 화면 코드를 크게 바꾸지 않고 확장할 수 있습니다.
///
/// [timetable]/[setlist]는 백엔드에서 공연 정보를 조회해 채워지는 값으로,
/// 아직 연동 전이거나 백엔드에 데이터가 없으면 빈 리스트로 두면 됩니다(화면에는 "미정"으로 표시됨).
///
/// [posterImageUrl]도 마찬가지로 백엔드에서 공연 포스터 이미지를 조회해 채워지는 값입니다.
/// 아직 연동 전이거나 등록된 포스터가 없으면 null로 두면 됩니다(화면에는 예시 그라데이션이 표시됨).
///
/// [deliveryDate]/[vendorName]은 "배송 전" 티켓에서 쓰는 값으로, 백엔드에서 실물 티켓의
/// 배송 예정일과 예매처 이름을 조회해 채워집니다. 아직 연동 전이면 null로 두면 됩니다
/// (화면에는 배송일 대신 D-00, 예매처 대신 "예매처"가 표시됨).
@immutable
class TicketInfo {
  final String concertName;
  final String venueName;
  final DateTime? date;
  final String price;
  final String seat;
  final Map<String, String> extraFields;
  final List<TimetableEntry> timetable;
  final List<String> setlist;
  final String? posterImageUrl;
  final DateTime? deliveryDate;
  final String? vendorName;

  const TicketInfo({
    this.concertName = '',
    this.venueName = '',
    this.date,
    this.price = '',
    this.seat = '',
    this.extraFields = const {},
    this.timetable = const [],
    this.setlist = const [],
    this.posterImageUrl,
    this.deliveryDate,
    this.vendorName,
  });

  TicketInfo copyWith({
    String? concertName,
    String? venueName,
    DateTime? date,
    String? price,
    String? seat,
    Map<String, String>? extraFields,
    List<TimetableEntry>? timetable,
    List<String>? setlist,
    String? posterImageUrl,
    DateTime? deliveryDate,
    String? vendorName,
  }) {
    return TicketInfo(
      concertName: concertName ?? this.concertName,
      venueName: venueName ?? this.venueName,
      date: date ?? this.date,
      price: price ?? this.price,
      seat: seat ?? this.seat,
      extraFields: extraFields ?? this.extraFields,
      timetable: timetable ?? this.timetable,
      setlist: setlist ?? this.setlist,
      posterImageUrl: posterImageUrl ?? this.posterImageUrl,
      deliveryDate: deliveryDate ?? this.deliveryDate,
      vendorName: vendorName ?? this.vendorName,
    );
  }

  String get formattedDate {
    final d = date;
    if (d == null) return '-';
    return '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
  }

  /// 화면에 순서대로 노출할 (라벨, 값) 목록.
  /// extraFields가 뒤에 이어 붙기 때문에, 필드가 늘어나도 UI가 그대로 대응합니다.
  List<MapEntry<String, String>> get displayFields => [
    MapEntry('공연장', venueName.isEmpty ? '-' : venueName),
    MapEntry('날짜', formattedDate),
    MapEntry('가격', price.isEmpty ? '-' : price),
    MapEntry('좌석', seat.isEmpty ? '-' : seat),
    ...extraFields.entries,
  ];
}
