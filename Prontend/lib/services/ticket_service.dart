import 'dart:async';

import '../models/page_layout.dart';
import '../models/ticket_response.dart';
import 'api_client.dart';
import 'favorites_store.dart';

/// 이미 그 공연에 등록된 티켓이 있을 때(백엔드가 409로 응답).
class TicketAlreadyRegisteredException implements Exception {
  const TicketAlreadyRegisteredException();
}

/// 대상 티켓이 이미 삭제됐거나 없을 때(백엔드가 404로 응답).
class TicketNotFoundException implements Exception {
  const TicketNotFoundException();
}

// [백엔드 수정]
// 게스트도 카카오와 동일하게 서버 `/tickets` API를 쓰도록 변경(LocalTicketStore 분기 제거).
/// 티켓 CRUD 서비스. 그대로 백엔드 `/tickets` API를 씁니다.
class TicketService {
  TicketService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  /// 티켓 등록. 백엔드 `TicketCreate`(schemas/ticket.py)와 동일한 필드명을 씁니다.
  /// [concertId]/[kopisId] 중 하나는 필수(백엔드 model_validator와 동일한 제약).
  // [백엔드 수정]
  // TicketCreate.start_time 파라미터 추가. OCR로 읽은 시작시간(extracted.time) 서버에 저장.
  // attendedDate도 같은 이유로 추가.
  Future<TicketWithConcert> createTicket({
    String? concertId,
    String? kopisId,
    DateTime? deliveryDate,
    String? startTime,
    DateTime? attendedDate,
    String? ticketingSite,
    int? price,
    String? seatType,
    // [백엔드 수정] 실물 배송을 기다리는 중이면 배송 전 티켓으로 등록.
    bool awaitingDelivery = false,
  }) async {
    assert(
      concertId != null || kopisId != null,
      'concertId 또는 kopisId 중 하나는 필수입니다.',
    );

    try {
      final json = await _client.post(
        '/tickets',
        body: {
          'concert_id': ?concertId,
          'kopis_id': ?kopisId,
          if (deliveryDate != null)
            'delivery_date': deliveryDate.toIso8601String(),
          'start_time': ?startTime,
          if (attendedDate != null)
            'attended_date': attendedDate.toIso8601String(),
          'ticketing_site': ?ticketingSite,
          'price': ?price,
          'seat_type': ?seatType,
          if (awaitingDelivery) 'awaiting_delivery': true,
        },
      );
      final ticket = TicketWithConcert.fromJson(json);

      // [백엔드 수정]
      // 티켓을 등록시 서버가 자동으로 찜 해제.
      // FavoritesStore 로컬 캐시는 여기서 직접 반영.
      final concertName = ticket.concert?.name;
      if (concertName != null) {
        unawaited(FavoritesStore.instance.removeConcert(concertName));
      }

      return ticket;
    } on ApiException catch (e) {
      if (e.statusCode == 409) throw const TicketAlreadyRegisteredException();
      rethrow;
    }
  }

  /// 내 티켓 목록 조회(`GET /tickets`). 공연 전 티켓을 먼저, 그중 공연일이
  /// 가까운 순으로 정렬해서 줍니다.
  Future<List<TicketWithConcert>> listTickets() async {
    final list = await _client.getList('/tickets');
    return list
        .map((e) => TicketWithConcert.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // [백엔드 수정] 아티스트 연결 수정 후 공연 정보 '아티스트' 칸 갱신용 단건 조회.
  Future<TicketWithConcert> getTicket(String ticketId) async {
    final json = await _client.get('/tickets/$ticketId');
    return TicketWithConcert.fromJson(json);
  }

  /// 티켓 부분 수정(`PATCH /tickets/{id}`). 값을 넘긴 필드만 갱신되고,
  /// 넘기지 않은 필드는 그대로 유지됩니다.
  ///
  /// 백엔드 `TicketUpdate`엔 `status`가 없다는 점에 주의하세요 — 티켓 상태
  /// (배송전/공연전/공연후)는 이 API로 직접 바꿀 수 없고, 서버 배치 작업이
  /// 공연 종료 여부를 보고 자동으로 전환합니다.
  Future<TicketWithConcert> updateTicket(
    String ticketId, {
    DateTime? deliveryDate,
    // [백엔드 수정]
    // TicketUpdate.start_time/attended_date 파라미터 추가(createTicket과 같은 이유).
    String? startTime,
    DateTime? attendedDate,
    String? ticketingSite,
    int? price,
    String? seatType,
    String? ticketImageUrl,
    String? review,
    List<String>? concertPhotoUrls,
    bool? isFirstDay,
    bool? isLastDay,
    // "공연 후" 입장 티켓 뜯기 연출 실행 시각. [clearTornAt]이 true면
    // (tornAt 값과 무관하게) 명시적으로 null로 되돌립니다 — 나머지 필드처럼
    // "값을 안 넘기면 그대로 둠"만으로는 "null로 지우기"를 표현할 수 없어서
    // 별도 플래그가 필요합니다.
    DateTime? tornAt,
    bool clearTornAt = false,
    // [백엔드 수정] 공연후 페이지 배치 전체 교체
    PageLayout? pageLayout,
  }) async {
    try {
      final json = await _client.patch(
        '/tickets/$ticketId',
        body: {
          if (deliveryDate != null)
            'delivery_date': deliveryDate.toIso8601String(),
          'start_time': ?startTime,
          if (attendedDate != null)
            'attended_date': attendedDate.toIso8601String(),
          'ticketing_site': ?ticketingSite,
          'price': ?price,
          'seat_type': ?seatType,
          'ticket_image_url': ?ticketImageUrl,
          'review': ?review,
          'concert_photo_urls': ?concertPhotoUrls,
          'is_first_day': ?isFirstDay,
          'is_last_day': ?isLastDay,
          if (tornAt != null) 'torn_at': tornAt.toIso8601String(),
          if (clearTornAt) 'torn_at': null,
          if (pageLayout != null) 'page_layout': pageLayout.toJson(),
        },
      );
      return TicketWithConcert.fromJson(json);
    } on ApiException catch (e) {
      if (e.statusCode == 404) throw const TicketNotFoundException();
      rethrow;
    }
  }

  // [백엔드 수정] 배송 전 티켓을 스캔 없이 공연 전으로 넘김(이미 받았거나 모바일 티켓).
  Future<TicketWithConcert> markDelivered(String ticketId) async {
    try {
      final json = await _client.post('/tickets/$ticketId/delivered');
      return TicketWithConcert.fromJson(json);
    } on ApiException catch (e) {
      if (e.statusCode == 404) throw const TicketNotFoundException();
      rethrow;
    }
  }

  /// 티켓 삭제(`DELETE /tickets/{id}`).
  Future<void> deleteTicket(String ticketId) async {
    try {
      await _client.delete('/tickets/$ticketId');
    } on ApiException catch (e) {
      if (e.statusCode == 404) throw const TicketNotFoundException();
      rethrow;
    }
  }
}
