import '../models/ticket_response.dart';
import '../models/ticket_scan.dart' show ConcertResponse;
import 'api_client.dart';
import 'auth_service.dart';
import 'local_ticket_store.dart';

/// 이미 그 공연에 등록된 티켓이 있을 때(백엔드가 409로 응답, 게스트는
/// [LocalTicketStore]가 동일한 규칙으로 직접 판단).
class TicketAlreadyRegisteredException implements Exception {
  const TicketAlreadyRegisteredException();
}

/// 대상 티켓이 이미 삭제됐거나 없을 때(백엔드가 404로 응답, 게스트는
/// [LocalTicketStore]가 동일한 규칙으로 직접 판단).
class TicketNotFoundException implements Exception {
  const TicketNotFoundException();
}

/// 티켓 CRUD 서비스.
///
/// 게스트 로그인 상태([AuthService.isGuest])면 서버로 아무것도 보내지 않고
/// [LocalTicketStore](기기 로컬 저장)로 위임합니다 — 앱을 지우면 이 데이터도
/// 함께 사라집니다. 카카오 로그인 상태면 그대로 백엔드 `/tickets` API를
/// 씁니다. 게스트→카카오 전환 시 로컬 데이터를 서버로 옮기는 로직은
/// [GuestMigrationService]가 별도로 담당합니다.
class TicketService {
  TicketService({ApiClient? client}) : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  bool get _isGuest => AuthService.instance.isGuest;

  /// 티켓 등록. 백엔드 `TicketCreate`(schemas/ticket.py)와 동일한 필드명을 씁니다.
  /// [concertId]/[kopisId] 중 하나는 필수(백엔드 model_validator와 동일한 제약).
  ///
  /// [concert]는 게스트 저장(로컬)에만 쓰입니다 — 로컬에는 공연 조회용 DB가
  /// 없어서, 검색 결과로 이미 들고 있는 공연 정보를 그대로 함께 저장해둬야
  /// 다이어리 화면에 공연명/포스터 등을 보여줄 수 있습니다. 카카오 로그인
  /// 상태(백엔드 저장)에서는 무시됩니다.
  Future<TicketWithConcert> createTicket({
    String? concertId,
    String? kopisId,
    ConcertResponse? concert,
    DateTime? deliveryDate,
    String? ticketingSite,
    int? price,
    String? seatType,
  }) async {
    assert(
      concertId != null || kopisId != null,
      'concertId 또는 kopisId 중 하나는 필수입니다.',
    );

    if (_isGuest) {
      assert(concert != null, '게스트 티켓 저장에는 concert 정보가 필요합니다.');
      return LocalTicketStore.instance.createTicket(
        concert: concert!,
        deliveryDate: deliveryDate,
        ticketingSite: ticketingSite,
        price: price,
        seatType: seatType,
      );
    }

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

  /// 내 티켓 목록 조회. 게스트는 로컬 저장소, 카카오는 `GET /tickets`.
  /// 두 경우 모두 공연 전 티켓을 먼저, 그중 공연일이 가까운 순으로 정렬해서 줍니다.
  Future<List<TicketWithConcert>> listTickets() async {
    if (_isGuest) return LocalTicketStore.instance.listTickets();

    final list = await _client.getList('/tickets');
    return list
        .map((e) => TicketWithConcert.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 티켓 부분 수정. 게스트는 로컬 저장소, 카카오는 `PATCH /tickets/{id}`.
  /// 값을 넘긴 필드만 갱신되고, 넘기지 않은 필드는 그대로 유지됩니다.
  ///
  /// 백엔드 `TicketUpdate`엔 `status`가 없다는 점에 주의하세요 — 티켓 상태
  /// (배송전/공연전/공연후)는 이 API로 직접 바꿀 수 없고, 서버 배치 작업(또는
  /// 게스트는 [LocalTicketStore]가 조회 시점에)이 공연 종료 여부를 보고
  /// 자동으로 전환합니다.
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
    if (_isGuest) {
      return LocalTicketStore.instance.updateTicket(
        ticketId,
        deliveryDate: deliveryDate,
        ticketingSite: ticketingSite,
        price: price,
        seatType: seatType,
        ticketImageUrl: ticketImageUrl,
        review: review,
        concertPhotoUrls: concertPhotoUrls,
        isFirstDay: isFirstDay,
        isLastDay: isLastDay,
      );
    }

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

  /// 티켓 삭제. 게스트는 로컬 저장소에서, 카카오는 `DELETE /tickets/{id}`로
  /// 서버에서 완전히 제거합니다.
  Future<void> deleteTicket(String ticketId) async {
    if (_isGuest) return LocalTicketStore.instance.deleteTicket(ticketId);

    try {
      await _client.delete('/tickets/$ticketId');
    } on ApiException catch (e) {
      if (e.statusCode == 404) throw const TicketNotFoundException();
      rethrow;
    }
  }
}
