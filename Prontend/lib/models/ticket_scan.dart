import 'package:flutter/foundation.dart';

/// 공연 좌석 등급별 가격 항목. 백엔드 `schemas/concert.py`의 `PriceEntry`와 대응.
@immutable
class PriceEntry {
  final String seatType;
  final int price;

  const PriceEntry({required this.seatType, required this.price});

  factory PriceEntry.fromJson(Map<String, dynamic> json) {
    return PriceEntry(
      seatType: json['seat_type'] as String,
      price: json['price'] as int,
    );
  }

  Map<String, dynamic> toJson() => {'seat_type': seatType, 'price': price};
}

/// 공연 정보(= KOPIS 매칭 후보 1건). 백엔드 `ConcertResponse`와 대응.
@immutable
class ConcertResponse {
  final String id;
  final String? kopisId;
  final String name;
  final List<String> artistName;
  final String? venue;
  final DateTime startDate;
  final DateTime endDate;
  final List<String>? genre;
  final String? posterUrl;
  final String? description;
  final List<PriceEntry>? price;
  final String eventType;
  final DateTime? ticketingDate;

  const ConcertResponse({
    required this.id,
    this.kopisId,
    required this.name,
    required this.artistName,
    this.venue,
    required this.startDate,
    required this.endDate,
    this.genre,
    this.posterUrl,
    this.description,
    this.price,
    required this.eventType,
    this.ticketingDate,
  });

  factory ConcertResponse.fromJson(Map<String, dynamic> json) {
    return ConcertResponse(
      id: json['id'] as String,
      kopisId: json['kopis_id'] as String?,
      name: json['name'] as String,
      artistName: (json['artist_name'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
      venue: json['venue'] as String?,
      startDate: DateTime.parse(json['start_date'] as String),
      endDate: DateTime.parse(json['end_date'] as String),
      genre: (json['genre'] as List<dynamic>?)?.map((e) => e as String).toList(),
      posterUrl: json['poster_url'] as String?,
      description: json['description'] as String?,
      price: (json['price'] as List<dynamic>?)
          ?.map((e) => PriceEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      eventType: json['event_type'] as String,
      ticketingDate: json['ticketing_date'] != null
          ? DateTime.parse(json['ticketing_date'] as String)
          : null,
    );
  }

  /// [LocalTicketStore]가 게스트 티켓과 함께 저장할 공연 정보 스냅샷을
  /// 만드는 데 씁니다(백엔드로 보내는 요청 body가 아니라 로컬 직렬화 용도).
  Map<String, dynamic> toJson() => {
    'id': id,
    'kopis_id': kopisId,
    'name': name,
    'artist_name': artistName,
    'venue': venue,
    'start_date': startDate.toIso8601String(),
    'end_date': endDate.toIso8601String(),
    'genre': genre,
    'poster_url': posterUrl,
    'description': description,
    'price': price?.map((e) => e.toJson()).toList(),
    'event_type': eventType,
    'ticketing_date': ticketingDate?.toIso8601String(),
  };
}

/// OCR(Vision API) + 정규식 파싱으로 추출된 티켓 정보.
/// 백엔드 `TicketScanExtracted`와 대응(날짜류는 백엔드와 동일하게
/// "YYYY-MM-DD" 원문 문자열 그대로 보관합니다).
@immutable
class TicketScanExtracted {
  final String? title;
  final String? date;
  final String? time;
  final String? location;
  final String? seat;
  final String? platform;
  final int? price;
  final String? shippingDate;
  final String? eventType;

  const TicketScanExtracted({
    this.title,
    this.date,
    this.time,
    this.location,
    this.seat,
    this.platform,
    this.price,
    this.shippingDate,
    this.eventType,
  });

  factory TicketScanExtracted.fromJson(Map<String, dynamic> json) {
    return TicketScanExtracted(
      title: json['title'] as String?,
      date: json['date'] as String?,
      time: json['time'] as String?,
      location: json['location'] as String?,
      seat: json['seat'] as String?,
      platform: json['platform'] as String?,
      price: json['price'] as int?,
      shippingDate: json['shipping_date'] as String?,
      eventType: json['event_type'] as String?,
    );
  }
}

/// `POST /concerts/scan` 응답. 백엔드 `TicketScanResponse`와 대응.
@immutable
class TicketScanResponse {
  final TicketScanExtracted extracted;
  final List<ConcertResponse> candidates;

  const TicketScanResponse({required this.extracted, required this.candidates});

  factory TicketScanResponse.fromJson(Map<String, dynamic> json) {
    return TicketScanResponse(
      extracted: TicketScanExtracted.fromJson(
        json['extracted'] as Map<String, dynamic>,
      ),
      candidates: (json['candidates'] as List<dynamic>? ?? const [])
          .map((e) => ConcertResponse.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
