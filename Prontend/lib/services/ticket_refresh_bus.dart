import 'package:flutter/foundation.dart';

/// "다른 화면에서 티켓 데이터가 바뀌었으니 다시 불러와라"를 알리는 간단한
/// 알림 버스.
///
/// [DiaryScreen]은 유저 id가 바뀔 때만([AuthService]의 리스너로) 티켓을
/// 다시 불러오는데, 게스트→카카오 마이그레이션([GuestMigrationService])은
/// 유저 id가 바뀐 "직후"에 로컬 티켓들을 백엔드로 업로드하므로, 그 시점엔
/// 이미 유저 id 변경 이벤트가 지나가버려 다이어리 화면이 새로 생긴 백엔드
/// 티켓을 알 방법이 없습니다. 업로드가 다 끝난 뒤 이 버스로 한 번 더
/// 알려서 다이어리 화면이 강제로 다시 불러오게 합니다.
class TicketRefreshBus {
  TicketRefreshBus._();

  static final ValueNotifier<int> tick = ValueNotifier(0);

  static void notify() => tick.value++;
}
