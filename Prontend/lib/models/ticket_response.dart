import 'package:flutter/foundation.dart';

import 'ticket_scan.dart' show ConcertResponse;

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
      isLastDay: isLastDay ?? this.isLastDay,
      concert: concert,
    );
  }
}
