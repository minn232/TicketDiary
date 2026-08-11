import 'package:image_picker/image_picker.dart';

import 'auth_service.dart';
import 'local_ticket_store.dart';
import 'ticket_refresh_bus.dart';
import 'ticket_service.dart';
import 'upload_service.dart';

/// [GuestMigrationService.migrateGuestDataToKakao] 결과.
class GuestMigrationResult {
  final int migratedCount;
  final int failedCount;

  const GuestMigrationResult({
    required this.migratedCount,
    required this.failedCount,
  });

  bool get hasFailures => failedCount > 0;
}

// [백엔드 수정]
// 게스트도 등록 시점부터 서버 저장(TicketService 참고)이라, 이 마이그레이션은
// 이전 로컬 전용 레거시 게스트 티켓 대상 하위호환 경로로만 남음. 신규
// 게스트는 localTickets가 항상 빈 리스트라 아래 for문이 안 돌고 바로 끝남 —
// 로직을 따로 줄이지 않아도 자연히 빠른 경로가 됨.
/// 게스트 로그인 상태에서 [LocalTicketStore]에 쌓아둔 티켓들을 카카오
/// 계정으로 옮깁니다.
///
/// `/auth/migrate`는 게스트 유저 row를 그대로 카카오 계정으로 승격시킬
/// 뿐(백엔드에 저장된 데이터가 없다면 옮길 것도 없음), 실제 티켓 데이터는
/// 로컬에만 있으므로 여기서 하나씩 `POST /tickets`로 새로 등록해야 합니다.
/// 사진이 로컬 파일 경로(기기 저장)라면 등록 전에 먼저 서버에 업로드해
/// 실제 URL로 바꿔둡니다(그래야 재설치 후에도 사진이 남습니다).
class GuestMigrationService {
  GuestMigrationService._();

  static final GuestMigrationService instance = GuestMigrationService._();

  Future<GuestMigrationResult> migrateGuestDataToKakao(String code) async {
    final localTickets = await LocalTicketStore.instance.listTickets();

    // 토큰이 카카오 계정으로 바뀌는 순간부터 TicketService/UploadService는
    // 자동으로 백엔드를 바라보게 됩니다(AuthService.isGuest가 false가 됨).
    await AuthService.instance.completeKakaoLogin(code, migrateFromGuest: true);

    final ticketService = TicketService();
    final uploadService = BackendUploadService();

    var migrated = 0;
    var failed = 0;

    for (final ticket in localTickets) {
      final concert = ticket.concert;
      if (concert == null) {
        failed++;
        continue;
      }

      try {
        final uploadedPhotoUrls = <String>[];
        for (final url in ticket.concertPhotoUrls ?? const <String>[]) {
          if (url.startsWith('http://') || url.startsWith('https://')) {
            uploadedPhotoUrls.add(url);
            continue;
          }
          try {
            uploadedPhotoUrls.add(
              await uploadService.uploadConcertPhoto(XFile(url)),
            );
          } catch (_) {
            // 사진 하나가 실패해도 티켓 자체(후기/다른 사진)는 계속 옮깁니다.
          }
        }

        // [백엔드 수정]
        // startTime/attendedDate 전달 추가.
        final created = await ticketService.createTicket(
          concertId: concert.id,
          deliveryDate: ticket.deliveryDate,
          startTime: ticket.startTime,
          attendedDate: ticket.attendedDate,
          ticketingSite: ticket.ticketingSite,
          price: ticket.price,
          seatType: ticket.seatType,
        );

        final needsFollowUpUpdate =
            ticket.review != null ||
            uploadedPhotoUrls.isNotEmpty ||
            ticket.isFirstDay != null ||
            ticket.isLastDay != null;
        if (needsFollowUpUpdate) {
          await ticketService.updateTicket(
            created.id,
            review: ticket.review,
            concertPhotoUrls: uploadedPhotoUrls.isEmpty ? null : uploadedPhotoUrls,
            isFirstDay: ticket.isFirstDay,
            isLastDay: ticket.isLastDay,
          );
        }

        migrated++;
      } catch (_) {
        failed++;
      }
    }

    // 하나라도 실패하면 로컬 데이터를 지우지 않습니다 — 실패한 티켓은
    // 게스트 로컬 저장소에 그대로 남아 데이터가 사라지지 않도록 합니다
    // (이 계정은 이미 카카오로 전환됐으므로 화면에는 더 노출되지 않지만,
    // 기기에서 최소한 원본 데이터는 보존됩니다).
    if (failed == 0) {
      await LocalTicketStore.instance.clearAll();
    }

    TicketRefreshBus.notify();

    return GuestMigrationResult(migratedCount: migrated, failedCount: failed);
  }
}
