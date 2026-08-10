import 'package:flutter/foundation.dart';

import 'ticket_scan.dart' show ConcertResponse;

/// [TicketWithConcert.copyWith]의 [TicketWithConcert.tornAt] 파라미터 전용
/// 미지정 표시값. `null`은 "명시적으로 null로 지운다"는 뜻이라, "이 필드는
/// 건드리지 않는다"와 구분하려면 별도의 감시값이 필요합니다.
const Object _unset = Object();

/// 티켓 등록/조회 응답(공연 정보 포함). 백엔드 `schemas/ticket.py`의
/// `TicketResponse`/`TicketWithConcert`와 대응.
///
/// [status]는 백엔드 `TicketStatus` enum 값("before_delivery" / "before_concert"
/// / "after_concert") 문자열 그대로 보관합니다. 프론트 자체 상태 enum으로의
/// 변환은 화면 쪽(diary_screen.dart)에서 담당합니다.
@immutable
class TicketWithConcert {
  final String id;
  final String? concertId;
  final String status;
  final DateTime? deliveryDate;
  final String? ticketingSite;
  final int? price;
  final String? seatType;
  final String? ticketImageUrl;
  final String? review;
  final List<String>? concertPhotoUrls;
  final bool? isFirstDay;
  final bool? isLastDay;
  final ConcertResponse? concert;

  /// 공연 후 "입장 티켓 뜯기" 연출을 실행한 시각. null이면 아직 안 뜯긴
  /// 상태입니다. 백엔드는 이 값을 저장만 담당하고, 다시 안 뜯긴 상태로
  /// 되돌리는 단방향 강제는 프론트가 담당합니다.
  final DateTime? tornAt;

  const TicketWithConcert({
    required this.id,
    this.concertId,
    required this.status,
    this.deliveryDate,
    this.ticketingSite,
    this.price,
    this.seatType,
    this.ticketImageUrl,
    this.review,
    this.concertPhotoUrls,
    this.isFirstDay,
    this.isLastDay,
    this.concert,
    this.tornAt,
  });

  factory TicketWithConcert.fromJson(Map<String, dynamic> json) {
    return TicketWithConcert(
      id: json['id'] as String,
      concertId: json['concert_id'] as String?,
      status: json['status'] as String,
      deliveryDate: json['delivery_date'] != null
          ? DateTime.parse(json['delivery_date'] as String)
          : null,
      ticketingSite: json['ticketing_site'] as String?,
      price: json['price'] as int?,
      seatType: json['seat_type'] as String?,
      ticketImageUrl: json['ticket_image_url'] as String?,
      review: json['review'] as String?,
      concertPhotoUrls: (json['concert_photo_urls'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      isFirstDay: json['is_first_day'] as bool?,
      isLastDay: json['is_last_day'] as bool?,
      concert: json['concert'] != null
          ? ConcertResponse.fromJson(json['concert'] as Map<String, dynamic>)
          : null,
      tornAt: json['torn_at'] != null
          ? DateTime.parse(json['torn_at'] as String)
          : null,
    );
  }

  /// [LocalTicketStore]가 게스트 티켓을 shared_preferences에 직렬화해
  /// 저장하는 데 씁니다(백엔드로 보내는 요청 body가 아니라 로컬 저장 용도).
  Map<String, dynamic> toJson() => {
    'id': id,
    'concert_id': concertId,
    'status': status,
    'delivery_date': deliveryDate?.toIso8601String(),
    'ticketing_site': ticketingSite,
    'price': price,
    'seat_type': seatType,
    'ticket_image_url': ticketImageUrl,
    'review': review,
    'concert_photo_urls': concertPhotoUrls,
    'is_first_day': isFirstDay,
    'is_last_day': isLastDay,
    'concert': concert?.toJson(),
    'torn_at': tornAt?.toIso8601String(),
  };

  TicketWithConcert copyWith({
    String? status,
    DateTime? deliveryDate,
    String? ticketingSite,
    int? price,
    String? seatType,
    String? ticketImageUrl,
    String? review,
    List<String>? concertPhotoUrls,
    bool? isFirstDay,
    bool? isLastDay,
    // tornAt은 "명시적으로 null로 지운다"(재설정)가 유효한 동작이라, 다른
    // 필드처럼 `??`(null이면 안 건드림)로는 표현할 수 없습니다. 감시값으로
    // "안 넘김"과 "null로 지움"을 구분합니다.
    Object? tornAt = _unset,
  }) {
    return TicketWithConcert(
      id: id,
      concertId: concertId,
      status: status ?? this.status,
      deliveryDate: deliveryDate ?? this.deliveryDate,
      ticketingSite: ticketingSite ?? this.ticketingSite,
      price: price ?? this.price,
      seatType: seatType ?? this.seatType,
      ticketImageUrl: ticketImageUrl ?? this.ticketImageUrl,
      review: review ?? this.review,
      concertPhotoUrls: concertPhotoUrls ?? this.concertPhotoUrls,
      isFirstDay: isFirstDay ?? this.isFirstDay,
      tornAt: identical(tornAt, _unset) ? this.tornAt : tornAt as DateTime?,
      isLastDay: isLastDay ?? this.isLastDay,
      concert: concert,
    );
  }
}
