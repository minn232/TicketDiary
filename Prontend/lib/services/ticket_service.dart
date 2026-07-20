import '../models/ticket_response.dart';
import 'api_client.dart';

/// 이미 그 공연에 등록된 티켓이 있을 때(백엔드가 409로 응답).
class TicketAlreadyRegisteredException implements Exception {
  const TicketAlreadyRegisteredException();
}

/// 대상 티켓이 이미 삭제됐거나 없을 때(백엔드가 404로 응답).
class TicketNotFoundException implements Exception {
  const TicketNotFoundException();
}

/// 백엔드 `/tickets` API와 통신하는 서비스.
class TicketService {
  TicketService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  /// 티켓 등록. 백엔드 `TicketCreate`(schemas/ticket.py)와 동일한 필드명을 씁니다.
  /// [concertId]/[kopisId] 중 하나는 필수(백엔드 model_validator와 동일한 제약).
  Future<TicketWithConcert> createTicket({
    String? concertId,
    String? kopisId,
    DateTime? deliveryDate,
    String? ticketingSite,
    int? price,
    String? seatType,
  }) async {
    assert(
      concertId != null || kopisId != null,
      'concertId 또는 kopisId 중 하나는 필수입니다.',
    );

    try {
      final json = await _client.post(
        '/tickets',
        body: {
          if (concertId != null) 'concert_id': concertId,
          if (kopisId != null) 'kopis_id': kopisId,
          if (deliveryDate != null)
            'delivery_date': deliveryDate.toIso8601String(),
          if (ticketingSite != null) 'ticketing_site': ticketingSite,
          if (price != null) 'price': price,
          if (seatType != null) 'seat_type': seatType,
        },
      );
      return TicketWithConcert.fromJson(json);
    } on ApiException catch (e) {
      if (e.statusCode == 409) throw const TicketAlreadyRegisteredException();
      rethrow;
    }
  }

  /// 내 티켓 목록 조회(`GET /tickets`). 백엔드가 공연 전 티켓을 먼저, 그중
  /// 공연일이 가까운 순으로 정렬해서 줍니다.
  Future<List<TicketWithConcert>> listTickets() async {
    final list = await _client.getList('/tickets');
    return list
        .map((e) => TicketWithConcert.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 티켓 부분 수정(`PATCH /tickets/{id}`). 값을 넘긴 필드만 갱신되고,
  /// 넘기지 않은 필드는 그대로 유지됩니다(백엔드가 `exclude_unset`으로 처리).
  ///
  /// 백엔드 `TicketUpdate`엔 `status`가 없다는 점에 주의하세요 — 티켓 상태
  /// (배송전/공연전/공연후)는 이 API로 직접 바꿀 수 없고, 서버 배치 작업이
  /// 공연 종료 여부를 보고 자동으로 전환합니다.
  Future<TicketWithConcert> updateTicket(
    String ticketId, {
    DateTime? deliveryDate,
    String? ticketingSite,
    int? price,
    String? seatType,
    String? ticketImageUrl,
    String? review,
    List<String>? concertPhotoUrls,
    bool? isFirstDay,
    bool? isLastDay,
  }) async {
    try {
      final json = await _client.patch(
        '/tickets/$ticketId',
        body: {
          if (deliveryDate != null)
            'delivery_date': deliveryDate.toIso8601String(),
          if (ticketingSite != null) 'ticketing_site': ticketingSite,
          if (price != null) 'price': price,
          if (seatType != null) 'seat_type': seatType,
          if (ticketImageUrl != null) 'ticket_image_url': ticketImageUrl,
          if (review != null) 'review': review,
          if (concertPhotoUrls != null) 'concert_photo_urls': concertPhotoUrls,
          if (isFirstDay != null) 'is_first_day': isFirstDay,
          if (isLastDay != null) 'is_last_day': isLastDay,
        },
      );
      return TicketWithConcert.fromJson(json);
    } on ApiException catch (e) {
      if (e.statusCode == 404) throw const TicketNotFoundException();
      rethrow;
    }
  }

  /// 티켓 삭제(`DELETE /tickets/{id}`). 성공하면 서버에서 완전히 제거됩니다.
  Future<void> deleteTicket(String ticketId) async {
    try {
      await _client.delete('/tickets/$ticketId');
    } on ApiException catch (e) {
      if (e.statusCode == 404) throw const TicketNotFoundException();
      rethrow;
    }
  }
}
