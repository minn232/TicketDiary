import 'dart:convert';
import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ticket_response.dart';
import '../models/ticket_scan.dart';
import 'ticket_service.dart' show TicketAlreadyRegisteredException, TicketNotFoundException;

/// 게스트 로그인 상태의 티켓/사진을 "서버로 보내지 않고" 기기에만 저장하는
/// 저장소. 앱을 지우면 기기 저장소(이 값들이 저장되는 곳)도 함께 사라지므로,
/// 게스트 데이터가 자연스럽게 사라지는 요구사항을 만족합니다.
///
/// [TicketService]가 [AuthService.isGuest]일 때 이 클래스로 위임하고,
/// 카카오 로그인일 때는 그대로 백엔드 API를 씁니다. 카카오로 마이그레이션할
/// 때는 [GuestMigrationService]가 여기 저장된 티켓들을 읽어 백엔드에
/// 업로드한 뒤 [clearAll]로 정리합니다.
class LocalTicketStore {
  LocalTicketStore._();

  static final LocalTicketStore instance = LocalTicketStore._();

  static const _storageKey = 'guest_tickets_v1';

  /// KOPIS `end_date`는 UTC 자정으로 저장되므로, 백엔드
  /// (`services/ticket.py::_initial_status`)와 동일하게 +15시간(KST 다음날
  /// 자정)이 지나야 "공연 후"로 판단합니다.
  static const _afterConcertGrace = Duration(hours: 15);

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<List<Map<String, dynamic>>> _readRaw() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded.cast<Map<String, dynamic>>();
  }

  Future<void> _writeRaw(List<Map<String, dynamic>> tickets) async {
    final prefs = await _prefs;
    await prefs.setString(_storageKey, jsonEncode(tickets));
  }

  String _initialStatus(ConcertResponse concert) {
    final now = DateTime.now().toUtc();
    if (concert.endDate.toUtc().add(_afterConcertGrace).isBefore(now)) {
      return 'after_concert';
    }
    return 'before_concert';
  }

  TicketWithConcert _withComputedStatus(TicketWithConcert ticket) {
    final concert = ticket.concert;
    if (concert == null) return ticket;
    return ticket.copyWith(status: _initialStatus(concert));
  }

  /// 게스트 티켓 목록. 백엔드 `get_sorted_tickets`와 동일하게 "공연 전"
  /// 티켓을 먼저, 그중 공연일이 현재와 가까운 순으로 정렬합니다.
  Future<List<TicketWithConcert>> listTickets() async {
    final raw = await _readRaw();
    final tickets = raw
        .map((json) => _withComputedStatus(TicketWithConcert.fromJson(json)))
        .toList();

    final now = DateTime.now();
    tickets.sort((a, b) {
      final aAfter = a.status == 'after_concert';
      final bAfter = b.status == 'after_concert';
      if (aAfter != bAfter) return aAfter ? 1 : -1;

      final aStart = a.concert?.startDate;
      final bStart = b.concert?.startDate;
      if (aStart == null && bStart == null) return 0;
      if (aStart == null) return 1;
      if (bStart == null) return -1;
      final aDiff = aStart.difference(now).abs();
      final bDiff = bStart.difference(now).abs();
      return aDiff.compareTo(bDiff);
    });
    return tickets;
  }

  Future<bool> hasAnyTickets() async => (await _readRaw()).isNotEmpty;

  String _generateLocalId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = identityHashCode(Object());
    return 'guest_ticket_${now}_$rand';
  }

  Future<TicketWithConcert> createTicket({
    required ConcertResponse concert,
    DateTime? deliveryDate,
    String? startTime,
    String? ticketingSite,
    int? price,
    String? seatType,
  }) async {
    final raw = await _readRaw();
    final alreadyRegistered = raw.any(
      (json) => json['concert']?['id'] == concert.id,
    );
    if (alreadyRegistered) {
      throw const TicketAlreadyRegisteredException();
    }

    final ticket = TicketWithConcert(
      id: _generateLocalId(),
      concertId: concert.id,
      status: _initialStatus(concert),
      deliveryDate: deliveryDate,
      ticketingSite: ticketingSite,
      price: price,
      seatType: seatType,
      concert: concert,
    );

    raw.add(ticket.toJson());
    await _writeRaw(raw);
    return ticket;
  }

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
    DateTime? tornAt,
    bool clearTornAt = false,
  }) async {
    final raw = await _readRaw();
    final index = raw.indexWhere((json) => json['id'] == ticketId);
    if (index == -1) throw const TicketNotFoundException();

    final current = TicketWithConcert.fromJson(raw[index]);
    final updated = current.copyWith(
      deliveryDate: deliveryDate,
      ticketingSite: ticketingSite,
      price: price,
      seatType: seatType,
      ticketImageUrl: ticketImageUrl,
      review: review,
      concertPhotoUrls: concertPhotoUrls,
      isFirstDay: isFirstDay,
      isLastDay: isLastDay,
      tornAt: clearTornAt ? null : (tornAt ?? current.tornAt),
    );

    raw[index] = updated.toJson();
    await _writeRaw(raw);
    return _withComputedStatus(updated);
  }

  Future<void> deleteTicket(String ticketId) async {
    final raw = await _readRaw();
    final index = raw.indexWhere((json) => json['id'] == ticketId);
    if (index == -1) throw const TicketNotFoundException();
    raw.removeAt(index);
    await _writeRaw(raw);
  }

  /// 사진을 앱 문서 디렉토리(`guest_photos/`)에 복사해 절대 경로를
  /// 반환합니다. 서버에 업로드하지 않으므로 앱을 지우면 함께 사라집니다.
  /// (Flutter Web은 파일 시스템이 없어 지원하지 않음 — 호출 쪽에서 분기)
  Future<String> saveImageLocally(XFile image) async {
    final bytes = await image.readAsBytes();
    final docsDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${docsDir.path}/guest_photos');
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }

    final originalName = image.name;
    final dotIndex = originalName.lastIndexOf('.');
    final ext = dotIndex != -1 ? originalName.substring(dotIndex) : '.jpg';
    final filename = '${DateTime.now().microsecondsSinceEpoch}$ext';
    final file = File('${photosDir.path}/$filename');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 게스트 데이터를 전부 지웁니다. 카카오 계정으로 성공적으로 옮긴
  /// 뒤([GuestMigrationService])나 회원 상태가 리셋될 때 호출합니다.
  Future<void> clearAll() async {
    final raw = await _readRaw();
    for (final json in raw) {
      final urls = (json['concert_photo_urls'] as List<dynamic>?) ?? const [];
      for (final url in urls) {
        if (url is String && !url.startsWith('http')) {
          try {
            final file = File(url);
            if (await file.exists()) await file.delete();
          } catch (_) {
            // 파일이 이미 없거나 삭제 실패해도 데이터 정리 자체는 계속 진행합니다.
          }
        }
      }
    }
    final prefs = await _prefs;
    await prefs.remove(_storageKey);
  }
}
