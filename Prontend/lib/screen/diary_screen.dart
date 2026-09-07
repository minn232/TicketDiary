import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'concert_after_overlay.dart';
import 'concert_before_overlay.dart';
import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/models/ticket_response.dart';
import 'package:ticketdiary/models/ticket_scan.dart';
import 'package:ticketdiary/services/api_client.dart';
import 'package:ticketdiary/services/app_settings_store.dart';
import 'package:ticketdiary/services/auth_service.dart';
import 'package:ticketdiary/services/ticket_refresh_bus.dart';
import 'package:ticketdiary/services/ticket_scan_service.dart';
import 'package:ticketdiary/services/ticket_service.dart';
import 'package:ticketdiary/services/torn_ticket_store.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';
import 'package:ticketdiary/widgets/add_ticket_option.dart';
import 'package:ticketdiary/widgets/entry_ticket_tear_piece.dart';
import 'package:ticketdiary/widgets/pressable_scale.dart';
import 'package:ticketdiary/widgets/responsive_text.dart';
import 'package:ticketdiary/widgets/sparkle_highlight.dart';
import 'package:ticketdiary/widgets/ticket_flip_card.dart';
import 'package:ticketdiary/widgets/diary_page_flipper.dart';
import 'package:ticketdiary/widgets/ticket_scan_camera_screen.dart';
import 'package:ticketdiary/widgets/app_network_image.dart';

class TicketData {
  final String title;
  final TicketStatus status;

  /// 스캔으로 추출된 상세 정보(공연장/날짜/가격/좌석 등). 없을 수도 있습니다.
  /// "공연 후" 오버레이에서 사진/소감을 저장하면 그 결과를 [_buildTicketAfterConcert]의
  /// onInfoChanged 콜백으로 여기 그대로 반영합니다(같은 [TicketData] 인스턴스를
  /// 유지해야 overlayKey 등 다른 상태가 끊기지 않으므로 final이 아닙니다).
  TicketInfo? info;

  /// 오버레이 확장 애니메이션의 시작 위치(Rect)를 구하기 위한 티켓별 고유 key.
  /// 여러 티켓이 동시에 화면(앞/뒷 페이지)에 존재할 수 있으므로 티켓마다 별도로 가져야 합니다.
  final GlobalKey overlayKey;

  /// "공연 후" 티켓의 포스터(왼쪽) 영역 전용 key. [ConcertAfterOverlay]가
  /// 이 자리에서 시작해 확장되도록, [overlayKey](오른쪽 "뜯긴 뒤" 영역)와는
  /// 별도로 관리합니다.
  final GlobalKey posterOverlayKey;

  /// 티켓의 고유 식별자. 공연 전 -> 공연 후로 상태가 바뀔 때 title이 함께
  /// 바뀔 수도 있으므로(예: 예시 티켓), title과 무관하게 같은 티켓임을
  /// 추적하기 위해 씁니다. 상태 전환 시 [_promoteDueTickets]가 그대로 물려줍니다.
  final String id;

  /// "공연 후" 티켓의 "입장 티켓" 조각을 이미 뜯었는지 여부.
  /// [_tickets]가 static이라 다이어리 화면을 나갔다 돌아와도 같은 [TicketData]
  /// 인스턴스를 계속 쓰므로, 여기에 저장해두면 뜯긴 상태가 그대로 유지됩니다.
  bool tornRevealed;

  static int _nextId = 0;

  TicketData({
    required this.title,
    required this.status,
    this.info,
    String? id,
    this.tornRevealed = false,
  }) : overlayKey = GlobalKey(),
       posterOverlayKey = GlobalKey(),
       id = id ?? 'ticket_${_nextId++}';

  // [백엔드 수정]
  // `time`(공연 시각)이 백엔드에 ticket.start_time으로 서버에 저장됨에 따라
  // 아래 문서와 조회 우선순위(ticket.startTime 우선)를 갱신.
  /// 실제로 등록된 티켓([TicketWithConcert])으로부터 화면에 쓸
  /// [TicketData]를 만듭니다. `id`는 티켓의 실제 식별자를 그대로 씁니다
  /// (카카오 로그인이면 백엔드 발급 UUID, 게스트면 [LocalTicketStore]가
  /// 발급한 로컬 id — 이후 수정/삭제 시 [TicketService]가 그대로 이 id로
  /// 알맞은 쪽에 위임합니다).
  ///
  /// [scanExtracted]는 방금 스캔해서 만든 티켓일 때만 넘겨주면 됩니다
  /// (`GET /tickets`로 불러온 기존 티켓엔 없음). `time`(공연 시각)은
  /// 방금 스캔한 시점엔 [scanExtracted]에서, 재조회 시엔 서버에 저장된
  /// `ticket.startTime`에서 가져와 [TicketInfo.extraFields]에 반영합니다.
  /// `event_type`(단독공연/페스티벌)은 공연 자체에 저장되는 값이라 [scanExtracted]
  /// 없이도(=기존 티켓을 불러올 때도) 항상 채워집니다.
  factory TicketData.fromBackend(
    TicketWithConcert ticket, {
    TicketScanExtracted? scanExtracted,
  }) {
    final concert = ticket.concert;
    final extraFields = <String, String>{};

    final artistName = concert?.artistName;
    if (artistName != null && artistName.isNotEmpty) {
      extraFields['아티스트'] = artistName.join(', ');
    }
    final eventType = concert?.eventType;
    if (eventType != null && eventType.isNotEmpty) {
      extraFields['공연 유형'] = _eventTypeLabel(eventType);
    }
    final time = ticket.startTime ?? scanExtracted?.time;
    if (time != null && time.isNotEmpty) {
      extraFields['공연 시간'] = time;
    }

    return TicketData(
      title: concert?.name ?? '알 수 없는 공연',
      status: _ticketStatusFromBackend(ticket.status),
      info: TicketInfo(
        concertName: concert?.name ?? '',
        venueName: concert?.venue ?? '',
        date: concert?.startDate,
        price: ticket.price?.toString() ?? '',
        seat: ticket.seatType ?? '',
        posterImageUrl: concert?.posterUrl,
        deliveryDate: ticket.deliveryDate,
        vendorName: ticket.ticketingSite,
        concertId: concert?.id,
        extraFields: extraFields,
        ticketId: ticket.id,
        review: ticket.review,
        concertPhotoUrls: ticket.concertPhotoUrls,
      ),
      id: ticket.id,
      // 서버(또는 게스트는 LocalTicketStore)에 저장된 torn_at이 있으면
      // 그걸 우선합니다. 이 필드가 생기기 전에 이 기기에서 이미 뜯어본
      // 적이 있는 경우를 위해 TornTicketStore(로컬 전용, 구버전 호환용)도
      // 함께 확인합니다 — 둘 중 하나라도 뜯긴 기록이 있으면 뜯긴 채로
      // 보여줍니다 (TornTicketStore.ensureLoaded가 끝난 뒤에 호출된다는
      // 전제 — _loadTicketsFromBackend가 보장합니다).
      tornRevealed:
          ticket.tornAt != null || TornTicketStore.instance.isTorn(ticket.id),
    );
  }
}

enum TicketStatus { beforeDelivery, beforeConcert, afterConcert, error }

/// 백엔드 `TicketStatus`(schemas/ticket.py: before_delivery/before_concert/
/// after_concert) 문자열을 프론트 [TicketStatus]로 변환합니다.
TicketStatus _ticketStatusFromBackend(String status) {
  switch (status) {
    case 'before_delivery':
      return TicketStatus.beforeDelivery;
    case 'before_concert':
      return TicketStatus.beforeConcert;
    case 'after_concert':
      return TicketStatus.afterConcert;
    default:
      return TicketStatus.error;
  }
}

/// 백엔드 `Concert.event_type`("SOLO"/"FESTIVAL"/그 외)을 화면에 보여줄
/// 한국어 라벨로 바꿉니다.
String _eventTypeLabel(String eventType) {
  switch (eventType) {
    case 'FESTIVAL':
      return '페스티벌';
    case 'SOLO':
      return '단독공연';
    default:
      return eventType;
  }
}

class DiaryScreen extends StatefulWidget {
  const DiaryScreen({
    super.key,
    this.frameScaleOverride,
    this.frameMarginOverride,
  });

  /// [DiaryPageFrame.scaleOverride]/[marginEachSideOverride]를 그대로
  /// 전달합니다. null이면(실제 사용 시 항상 null) 기존처럼 프레임이 스스로
  /// 측정합니다 - 스플래시 미리보기 전용 파라미터입니다.
  final double? frameScaleOverride;
  final double? frameMarginOverride;

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  static const Color _paperColor = Color(0xFFF4F1E1);

  /// 포스터가 티켓에 녹아든 새 디자인([_PosterTicketFace] + [_TicketBarcodeStub])
  /// 사용 여부. 마음에 들지 않으면 이 값만 `false`로 바꾸면 기존 흰색 티켓
  /// 디자인으로 즉시 되돌아갑니다(기존 디자인 코드는 그대로 남아 있음).
  static const bool _usePosterTicketDesign = true;

  bool _isAddTicketExpanded = false;

  /// "공연 전 -> 공연 후" 전환 애니메이션이 재생되는 동안, 사용자가 다른 조작을
  /// 하다가 애니메이션을 놓치거나 겹쳐 실행되지 않도록 잠깐 막아둡니다.
  bool _interactionLocked = false;

  /// 다중 페이지 상태
  int _currentPageIndex = 0;

  /// 페이지 넘김 애니메이션 진행도(0.0~1.0). [DiaryPageFlipper]가 갱신하고,
  /// [DiaryPageFrame]이 구독해 바인더 링이 페이지 넘김과 같은 속도로
  /// 오른쪽부터 사라졌다가(넘어가는 동안) 다시 나타나는(넘김이 끝나면)
  /// 효과를 만드는 데 씁니다.
  final ValueNotifier<double> _flipAnimating = ValueNotifier(0.0);

  /// 첫 페이지는 티켓추가 버튼 + 티켓 3개(총 4개, 버튼도 티켓과 같은 높이),
  /// 이후 페이지부터는 티켓 4개씩 채웁니다. 페이지당 항목 수와 높이를
  /// 동일하게 맞추기 위해 다이어리 프레임을 A5 규격보다 세로로 더 길게
  /// 만들었습니다([DiaryPageFrame.diaryAspectRatio] 참고).
  static const int _firstPageTicketCapacity = 3;
  static const int _otherPageTicketCapacity = 4;

  /// 티켓 카드(및 티켓추가 버튼)의 가로:세로 비율.
  static const double _ticketAspectRatio = 156 / 60;

  /// 항목(카드) 사이 세로 간격.
  static const double _ticketSpacing = 30; // 50 * 0.6

  /// 연속 페이지 넘김 방지
  DateTime _lastFlipTime = DateTime.now();
  static const _flipCooldown = Duration(milliseconds: 450);

  /// 티켓 데이터 리스트 (백엔드 연동을 위해 초기값을 비웁니다)
  ///
  /// 예전엔 "배송 전"/"공연 전" 상태를 눈으로 확인하기 위한 예시 티켓을
  /// 미리 넣어뒀지만, 이제는 [_buildDebugTestTicketTab]([TEST-ONLY] 왼쪽
  /// 아래 테스트 탭)으로 원하는 상태의 더미 티켓을 언제든 즉석에서 추가해
  /// 볼 수 있어 필요 없어졌습니다.
  ///
  /// `static`인 이유: 다른 탭으로 이동했다가 "다이어리" 탭으로 돌아오면
  /// [DiaryTab] 라우팅 구조상(diary_tabs.dart의 `pushNamedAndRemoveUntil`)
  /// 매번 새 [DiaryScreen] State가 생성됩니다. 이 필드가 인스턴스 필드였다면
  /// 화면을 나갔다 돌아올 때마다 초기화돼서, 눌러서 "공연 후"로 전환해둔
  /// 티켓이 다시 "공연 전"으로 리셋되는 문제가 있었습니다. `static`으로 두면
  /// 앱이 실행되는 동안 State가 몇 번을 새로 생기든 같은 리스트를 계속
  /// 공유하므로 전환 결과가 유지됩니다.
  static final List<TicketData> _tickets = [];

  /// 공연 전 -> 공연 후로 전환 중인 티켓의 id들. 비어있지 않으면, 이 티켓을
  /// 제외한 화면 전체를 어둡게 해서 "지금 이 티켓이 바뀌고 있다"는 걸 강조합니다.
  /// title이 아니라 id로 추적하는 이유: 전환하면서 이름도 함께 바뀔 수 있어서,
  /// 이름이 바뀌어도 같은 티켓을 계속 가리킬 수 있어야 하기 때문입니다.
  Set<String> _transitionSpotlightIds = {};

  bool get _isSpotlightActive => _transitionSpotlightIds.isNotEmpty;

  /// 강조 오버레이에서 티켓의 화면상 위치(Rect)를 구하기 위한, id별 고유 key.
  final Map<String, GlobalKey> _highlightKeys = {};

  GlobalKey _highlightKeyFor(String id) {
    return _highlightKeys.putIfAbsent(id, () => GlobalKey());
  }

  /// 티켓 이미지 스캔(OCR + KOPIS 매칭 후보 조회, `POST /concerts/scan`).
  final TicketScanService _scanService = BackendTicketScanService();

  /// 갤러리에서 이미지를 고를 때 씁니다(카메라 촬영과 달리 라이브 프리뷰가
  /// 필요 없어서 `image_picker`만으로 충분합니다).
  final ImagePicker _imagePicker = ImagePicker();

  /// 티켓 등록(`POST /tickets`).
  final TicketService _ticketService = TicketService();

  /// "공연 전 -> 공연 후" 전환 페이드 지속 시간. 두 디자인이 겹쳐 보이는 구간이
  /// 보이도록 하되, 너무 늘어지지 않게 6초의 50% 속도(=3초)로 잡았다가,
  /// 다시 절반(1.5초)으로 줄였습니다.
  static const Duration _promotionFadeDuration = Duration(milliseconds: 1500);

  /// 전환을 강조하는 어두운 오버레이가 나타나고/사라지는 페이드 속도(역시 느리게).
  static const Duration _spotlightDimFadeDuration = Duration(milliseconds: 900);

  /// 강조 시작 후 실제 전환이 시작되기까지, 그리고 전환이 끝난 뒤 강조가
  /// 풀리기까지 각각 기다리는 시간. 어두워지는 페이드([_spotlightDimFadeDuration])가
  /// 다 끝나고도 잠깐 여유가 있어야 성급해 보이지 않아서, 그보다 넉넉하게 둡니다.
  ///
  /// 전체 타임라인이 대칭을 이루도록, "강조 시작" 쪽은
  /// [페이드인 0.9s] + [정적 유지 0.6s] = 1.5s 이고,
  /// "강조 해제" 쪽도 거울처럼 [정적 유지 0.6s] + [페이드아웃 0.9s] = 1.5s 로
  /// 맞춰져 있습니다(_runTicketPromotionSimulation 참고).
  static const Duration _spotlightHoldDuration = Duration(milliseconds: 1500);

  /// 백엔드에서 티켓 목록을 이미 불러왔는지. [_tickets]가 static이라 다이어리
  /// 화면을 나갔다 돌아올 때마다 [initState]가 다시 호출되는데, 이 플래그가
  /// 없으면 재방문할 때마다 같은 티켓이 중복으로 쌓입니다(앱 프로세스가 살아
  /// 있는 동안 1회만 불러오면 충분 — 새로 추가/삭제한 티켓은 그 자리에서
  /// [_tickets]를 직접 갱신하므로 매번 다시 불러올 필요가 없습니다).
  static bool _backendTicketsLoaded = false;

  /// 마지막으로 [_tickets]를 채운 로그인 유저의 id. 로그아웃/계정 전환으로
  /// 유저가 바뀌면 이전 유저의 서버 기원 티켓을 화면에서 지우고 새 유저
  /// 것으로 다시 불러오기 위해 씁니다([_onAuthChangedStatic] 참고).
  static String? _loadedForUserId;

  // [백엔드 수정]
  // AuthService 리스너를 인스턴스(initState/dispose)에 걸려있어 설정에서는 역할을 못함.
  // 인스턴스 대신 static으로 앱 실행 중 한 번만 등록.
  static bool _authListenerRegistered = false;

  static void _registerAuthListenerOnce() {
    if (_authListenerRegistered) return;
    _authListenerRegistered = true;
    AuthService.instance.addListener(_onAuthChangedStatic);
  }

  /// 로그인 상태가 바뀔 때마다(로그인/로그아웃/게스트↔카카오 전환) 호출됩니다.
  /// 로그인된 유저가 마지막으로 티켓을 불러왔던 유저와 다르면, 이전 유저의
  /// 실제 티켓을 지우고 다시 불러올 수 있도록 플래그를 리셋합니다. 다이어리
  /// 화면이 지금 떠 있으면 [TicketRefreshBus]로 즉시 반영을 알리고, 안
  /// 떠 있으면 리셋해둔 플래그 덕에 다음에 열릴 때 자연히 다시 불러옵니다.
  static void _onAuthChangedStatic() {
    final currentUserId = AuthService.instance.userId;
    if (currentUserId == _loadedForUserId) return;
    _loadedForUserId = currentUserId;
    _tickets.removeWhere((t) => t.info?.ticketId != null);
    _backendTicketsLoaded = false;
    TicketRefreshBus.notify();
  }

  @override
  void initState() {
    super.initState();
    // "공연 전" 페이지의 예상 셋 리스트 블러 여부에 쓰이는 설정값을 미리 불러옵니다.
    AppSettingsStore.instance.load();
    _registerAuthListenerOnce();
    TicketRefreshBus.tick.addListener(_onTicketsChangedElsewhere);
    unawaited(_loadTicketsFromBackend());
  }

  @override
  void dispose() {
    TicketRefreshBus.tick.removeListener(_onTicketsChangedElsewhere);
    _flipAnimating.dispose();
    super.dispose();
  }

  /// [TicketRefreshBus]가 알림을 보낼 때마다(게스트→카카오 마이그레이션 완료,
  /// 또는 위 [_onAuthChangedStatic]) 호출됩니다. 유저 id는 이미 그 시점에
  /// 바뀌어 있으므로, 여기서는 가드 없이 강제로 다시 불러옵니다.
  void _onTicketsChangedElsewhere() {
    if (mounted) {
      setState(() {
        _tickets.removeWhere((t) => t.info?.ticketId != null);
      });
    } else {
      _tickets.removeWhere((t) => t.info?.ticketId != null);
    }
    _backendTicketsLoaded = false;
    unawaited(_loadTicketsFromBackend());
  }

  /// 서버에 저장된 내 티켓 목록을 불러와 [_tickets]에 반영합니다.
  ///
  /// 이미 [_tickets]에 있는(예: 방금 스캔으로 막 추가한) 티켓과 id가 겹치면
  /// 먼저 지운 뒤 서버 응답으로 다시 채웁니다 — "서버 응답이 항상 최신
  /// 진실"이라는 원칙으로 처리해, 이 조회가 끝나기 전에 사용자가 스캔으로
  /// 티켓을 추가해도 화면에 같은 티켓이 두 번 뜨지 않습니다.
  ///
  /// - 주고받는 데이터: `GET /tickets` 응답(`TicketWithConcert` 배열,
  ///   `id`/`concert_id`/`status`/`delivery_date`/`ticketing_site`/`price`/
  ///   `seat_type`/`ticket_image_url`/`review`/`concert_photo_urls`/
  ///   `is_first_day`/`is_last_day`/`concert`)을 그대로 받아
  ///   [TicketData.fromBackend]로 변환합니다. 보내는 값은 없습니다(인증
  ///   헤더만 필요).
  /// - 실패(오프라인 등)하면 조용히 무시합니다 — 로컬 예시 티켓만으로도
  ///   화면은 정상적으로 뜨고, 다음에 다이어리 탭을 다시 열면 재시도합니다.
  Future<void> _loadTicketsFromBackend() async {
    if (_backendTicketsLoaded) return;
    _backendTicketsLoaded = true;
    try {
      // TicketData.fromBackend가 동기적으로 TornTicketStore를 읽으므로,
      // 티켓 목록을 변환하기 전에 먼저 다 불러와둡니다.
      await TornTicketStore.instance.ensureLoaded();
      final tickets = await _ticketService.listTickets();
      if (!mounted) return;
      setState(() {
        final fetchedIds = tickets.map((t) => t.id).toSet();
        _tickets.removeWhere((t) => fetchedIds.contains(t.id));
        _tickets.addAll(tickets.map(TicketData.fromBackend));
      });
      _loadedForUserId = AuthService.instance.userId;
    } catch (_) {
      _backendTicketsLoaded = false;
    }
  }

  /// 공연 시간이 이미 지난 "공연 전" 티켓인지 확인합니다.
  /// true면 반짝이는 효과([SparkleHighlight])가 표시되고, 눌렀을 때
  /// [_runTicketPromotionAnimation]으로 "공연 후" 전환이 시작됩니다.
  bool _isDueForPromotion(TicketData ticket) {
    final date = ticket.info?.date;
    return ticket.status == TicketStatus.beforeConcert &&
        date != null &&
        !date.isAfter(DateTime.now());
  }

  /// 사용자가 공연 시간이 지난 "공연 전" 티켓을 눌렀을 때, 다음 순서로
  /// "공연 후"로의 전환을 재생합니다.
  ///
  /// "강조 시작 - 전환 - 강조 끝"이 대칭을 이루도록, 아래 타임라인은
  /// 앞뒤가 완전히 거울처럼 맞물립니다.
  ///
  /// ```
  /// 0 ---- 0.9 ---- 1.5 [전환 시작] ---- 4.5 [전환 끝] ---- 5.1 ---- 6.0
  /// |-어두워짐-|-정지-|                          |-정지-|-밝아짐-|
  ///   0.9s     0.6s        3.0s(전환)              0.6s     0.9s
  /// ```
  ///
  /// 1. 누르는 즉시 주변을 어둡게(느린 페이드로) 하며 강조를 시작.
  /// 2. [_spotlightHoldDuration] 후 실제 상태 전환([_promotionFadeDuration]짜리
  ///    느린 페이드 인아웃) 시작. 이 대기 시간 안에서 위 어두워지는 페이드가
  ///    자연스럽게 끝나고([_spotlightDimFadeDuration]) 잠깐 정지 상태로 이어집니다.
  /// 3. 전환이 끝나고 나면, 대칭을 맞추기 위해 밝아지는 페이드([_spotlightDimFadeDuration])
  ///    시간만큼 미리 강조를 해제해서, 그 페이드가 딱 [_spotlightHoldDuration] 시점에
  ///    끝나도록 합니다(2번의 "어두워짐" 쪽 타이밍을 그대로 뒤집은 모양).
  Future<void> _runTicketPromotionAnimation(String id) async {
    if (_isSpotlightActive) return; // 이미 재생 중이면 중복 실행하지 않습니다.

    final ticket = _tickets.firstWhere(
      (t) => t.id == id,
      orElse: () => TicketData(title: '', status: TicketStatus.error),
    );
    if (!_isDueForPromotion(ticket)) return;

    // 1. 누르는 즉시 강조 시작(어두워지는 페이드가 여기서부터 시작됨) + 조작 잠금.
    setState(() {
      _transitionSpotlightIds = {id};
      _interactionLocked = true;
    });

    // 2. 강조 시작 얼마 후 실제 전환 시작.
    await Future.delayed(_spotlightHoldDuration);
    if (!mounted) return;
    _promoteTicket(id);

    // 전환(페이드) 지속 시간만큼 대기.
    await Future.delayed(_promotionFadeDuration);
    if (!mounted) return;

    // 3. "어두워짐"과 대칭을 이루도록, 밝아지는 페이드 시간만큼 미리 강조를
    //    해제합니다. 그 결과 밝아지는 페이드가 정확히 _spotlightHoldDuration
    //    시점에 끝나, 앞부분(어두워짐 0.9s + 정지 0.6s)과 완전히 거울 대칭이 됩니다.
    await Future.delayed(_spotlightHoldDuration - _spotlightDimFadeDuration);
    if (!mounted) return;
    setState(() {
      _transitionSpotlightIds = {};
      _interactionLocked = false;
    });
  }

  /// 공연 날짜/시간(D-day)이 지난 "공연 전" 티켓 하나를 "공연 후" 상태로 바꿉니다.
  void _promoteTicket(String id) {
    final index = _tickets.indexWhere((t) => t.id == id);
    if (index == -1) return;

    final ticket = _tickets[index];
    if (!_isDueForPromotion(ticket)) return;

    // "공연 전 티켓 예시"처럼 이름에 "공연 전"이 들어있으면, 전환하면서
    // 이름도 "공연 후"로 함께 바꿔줍니다(실제 공연명에는 영향 없음).
    final newTitle = ticket.title.contains('공연 전')
        ? ticket.title.replaceFirst('공연 전', '공연 후')
        : ticket.title;
    _tickets[index] = TicketData(
      title: newTitle,
      status: TicketStatus.afterConcert,
      info: ticket.info,
      id: ticket.id,
    );

    if (mounted) setState(() {});
  }

  /// 티켓 개수에 따라 필요한 전체 페이지 수를 계산합니다.
  /// (첫 페이지 3개 + 이후 페이지 4개씩)
  int get _totalPages {
    final ticketCount = _tickets.length;
    if (ticketCount <= _firstPageTicketCapacity) return 1;
    final remaining = ticketCount - _firstPageTicketCapacity;
    final extraPages = (remaining / _otherPageTicketCapacity).ceil();
    return 1 + extraPages;
  }

  /// 공연 전 신문의 "제 N 호" — 이 티켓이 몇 번째로 등록됐는지. _tickets는
  /// 최신 티켓이 앞(index 0)이라, 뒤에서부터 센 순번(오래된 것=1, 최신=총
  /// 개수)을 씁니다. 목록에서 못 찾으면(index -1) 총 개수로 둡니다.
  int _issueNumberForIndex(int index) =>
      index < 0 ? _tickets.length : _tickets.length - index;

  /// 해당 페이지에 표시할 티켓 목록(최신 티켓이 항상 앞쪽 페이지에 오도록 순서 유지).
  List<TicketData> _ticketsForPage(int pageIndex) {
    if (pageIndex == 0) {
      return _tickets.take(_firstPageTicketCapacity).toList();
    }
    final start =
        _firstPageTicketCapacity + (pageIndex - 1) * _otherPageTicketCapacity;
    if (start >= _tickets.length) return const [];
    final end = (start + _otherPageTicketCapacity).clamp(0, _tickets.length);
    return _tickets.sublist(start, end);
  }

  // [백엔드 수정]
  // 오버레이가 뜨는 동안, 복사본 티켓이 겹쳐보여,
  // 각 영역의 GlobalKey로 구분해서 실제로 복사된 그 영역만 숨도록 함.
  Key? _overlayHiddenRegionKey;

  Widget _hideWhileOverlayOpen({
    required Key regionKey,
    required Widget child,
  }) {
    final hidden = _overlayHiddenRegionKey == regionKey;
    return IgnorePointer(
      ignoring: hidden,
      child: Opacity(opacity: hidden ? 0.0 : 1.0, child: child),
    );
  }

  Rect? _globalRectOf(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft & box.size;
  }

  /// 카메라로 실시간 정렬 인식(초록 테두리) 스캔을 진행한 뒤,
  /// 사용자의 수정 없이 바로 다이어리에 추가합니다.
  ///
  /// 카메라 화면은 실제 스캔 결과([TicketScanResponse]) 또는 "임시 스캔"
  /// 디버그 버튼으로 나온 [DebugFakeScanRequested] 중 하나를 반환할 수 있어
  /// `Object`로 받아 분기합니다.
  Future<void> _startCameraScan() async {
    setState(() => _isAddTicketExpanded = false);

    final Object? scanResult = await Navigator.of(context).push<Object>(
      MaterialPageRoute(
        builder: (_) => TicketScanCameraScreen(scanService: _scanService),
        fullscreenDialog: true,
      ),
    );

    if (scanResult == null || !mounted) return;

    if (scanResult is DebugFakeScanRequested) {
      _addDebugFakeTicket();
      return;
    }
    if (scanResult is TicketScanResponse) {
      await _registerTicketFromScan(scanResult);
    }
  }

  /// "임시 스캔" 버튼 전용 테스트 티켓 추가. 카메라 촬영도, 백엔드 호출(OCR/
  /// KOPIS 매칭/티켓 등록)도 거치지 않고 화면에 바로 보여줄 더미 데이터를
  /// 추가합니다. concertId가 없으므로 공연 전 상세 화면도 서버 조회 없이
  /// 이 값을 그대로 보여줍니다(예시 티켓과 동일한 방식).
  void _addDebugFakeTicket() {
    setState(() {
      _tickets.insert(
        0,
        TicketData(
          title: '임시 스캔 테스트 공연',
          status: TicketStatus.beforeConcert,
          info: TicketInfo(
            concertName: '임시 스캔 테스트 공연',
            venueName: '테스트 공연장',
            date: DateTime.now().add(const Duration(days: 7)),
            price: '99000',
            seat: 'R석',
            vendorName: 'INTERPARK',
            // 포스터 티켓 디자인 확인용 샘플 이미지(CORS 허용이라 웹에서도 표시됨)
            posterImageUrl: 'https://picsum.photos/seed/ticket/400/600',
            extraFields: const {'아티스트': '테스트 아티스트', '공연 유형': '단독공연'},
          ),
        ),
      );
    });
    _showSnack('테스트용 임시 티켓이 추가되었습니다.');
  }

  /// 갤러리에서 고른 이미지로 OCR 스캔 + 공연 매칭을 진행합니다. 카메라로
  /// 촬영한 사진과 마찬가지로 [TicketScanService.scanTicket]은 이미지
  /// 출처(카메라/갤러리)를 구분하지 않으므로, 카메라 스캔과 완전히 동일한
  /// 파이프라인([_registerTicketFromScan])을 그대로 재사용합니다.
  Future<void> _pickFromGalleryAndAnalyze() async {
    setState(() => _isAddTicketExpanded = false);

    final XFile? picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
    );
    if (picked == null || !mounted) return; // 선택 취소

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    TicketScanResponse result;
    try {
      result = await _scanService.scanTicket(picked);
    } on ApiException catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // 로딩 다이얼로그 닫기
      _showSnack('이미지 인식에 실패했어요: ${e.message}');
      return;
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(context);
      _showSnack('스캔 중 오류가 발생했어요. 잠시 후 다시 시도해주세요.');
      return;
    }

    if (!mounted) return;
    Navigator.pop(context); // 로딩 다이얼로그 닫기
    await _registerTicketFromScan(result);
  }

  /// 새 티켓을 다이어리에 추가합니다. 방금 등록한 공연과 같은 "배송 전"
  /// 티켓이 이미 있었다면(같은 [matchConcertId], 또는 concertId가 없는
  /// 예시/테스트 티켓처럼 매칭할 값이 없으면 [matchTitle]로) 그 자리를
  /// 대신하는 것이므로 지우고 새 티켓으로 교체합니다. 실제 스캔 등록
  /// ([_registerTicketFromScan])과 테스트용 더미 티켓 추가가 이 로직을
  /// 그대로 공유합니다.
  void _insertTicketReplacingBeforeDelivery(
    TicketData newTicket, {
    String? matchConcertId,
    required String matchTitle,
  }) {
    setState(() {
      final normalizedTitle = matchTitle.trim().toLowerCase();
      _tickets.removeWhere((t) {
        if (t.status != TicketStatus.beforeDelivery) return false;
        final sameConcertId =
            matchConcertId != null && t.info?.concertId == matchConcertId;
        final sameTitle = t.title.trim().toLowerCase() == normalizedTitle;
        return sameConcertId || sameTitle;
      });
      _tickets.insert(0, newTicket);
    });
  }

  /// 스캔 결과(OCR 추출 정보 + KOPIS 매칭 후보)를 바탕으로 백엔드에 티켓을
  /// 등록합니다.
  ///
  /// - 매칭되는 공연이 하나도 없으면(candidates 비어있음) **등록을 허용하지
  ///   않고** 안내만 표시합니다 — KOPIS에서 찾은 공연과 매치될 때만 티켓을
  ///   저장한다는 정책을 그대로 구현한 부분입니다.
  /// - 후보가 여러 개면 사용자가 직접 하나를 고르게 합니다.
  /// - 후보가 정해지면 그 공연의 concert_id로 `POST /tickets`를 호출해
  ///   실제로 서버에 저장하고, 성공하면 그 응답으로 다이어리에 티켓을 추가합니다.
  Future<void> _registerTicketFromScan(TicketScanResponse scanResult) async {
    final candidates = scanResult.candidates;

    if (candidates.isEmpty) {
      _showSnack('일치하는 공연을 찾을 수 없어요. KOPIS에 등록되지 않은 공연일 수 있어요.');
      return;
    }

    final ConcertResponse? selected = candidates.length == 1
        ? candidates.first
        : await _pickConcertCandidate(candidates);
    if (selected == null || !mounted) return; // 여러 후보 중 아무것도 선택 안 하고 취소함

    final extracted = scanResult.extracted;
    // 모바일 티켓 캡쳐처럼 사진에 가격/좌석이 없는 경우, KOPIS 가격표
    // (candidate.price)로 채움 - 하나만 없으면 자동 추정, 추정 실패하거나
    // 둘 다 없으면 강제 선택 시트(닫기로 건너뛸 수 없음)로 넘어감.
    int? finalPrice = extracted.price;
    String? finalSeat = extracted.seat?.isNotEmpty == true
        ? extracted.seat
        : null;
    final tiers = selected.price;
    if (tiers != null && tiers.isNotEmpty) {
      PriceEntry? matched;
      if (finalPrice == null && finalSeat != null) {
        matched = _matchTierBySeat(finalSeat, tiers);
        if (matched != null) finalPrice = matched.price;
      } else if (finalPrice != null && finalSeat == null) {
        matched = _matchTierByPaidPrice(finalPrice, tiers);
        if (matched != null) finalSeat = matched.seatType;
      }

      // 자동 추정 실패(애초에 둘 다 없던 경우 포함)하면 반드시 고르게 함.
      if (finalPrice == null || finalSeat == null) {
        if (!mounted) return;
        final picked = await _pickPriceEntry(tiers);
        if (picked == null || !mounted) return; // 시트 안 고르고 화면 이탈
        finalPrice = picked.price;
        finalSeat = picked.seatType;
      }
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    try {
      final ticket = await _ticketService.createTicket(
        concertId: selected.id,
        deliveryDate: _parseYmd(extracted.shippingDate),
        // [백엔드 수정]
        // extracted.time을 버리지 않고 넘기도록 수정.
        startTime: extracted.time,
        // [백엔드 수정]
        // extracted.date(OCR 관람일)도 같은 이유로 넘기도록 수정.
        attendedDate: _parseYmd(extracted.date),
        ticketingSite: extracted.platform,
        price: finalPrice,
        seatType: finalSeat,
      );

      if (!mounted) return;
      Navigator.pop(context); // 로딩 다이얼로그 닫기

      _insertTicketReplacingBeforeDelivery(
        TicketData.fromBackend(ticket, scanExtracted: extracted),
        matchConcertId: ticket.concertId,
        matchTitle: ticket.concert?.name ?? selected.name,
      );
      _showSnack('다이어리에 티켓이 추가되었습니다.');
    } on TicketAlreadyRegisteredException {
      if (!mounted) return;
      Navigator.pop(context);
      _showSnack('이미 등록된 공연 티켓이에요.');
    } on ApiException catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      _showSnack('티켓 등록에 실패했어요: ${e.message}');
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(context);
      _showSnack('알 수 없는 오류가 발생했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  /// KOPIS 매칭 후보가 여러 개일 때 사용자가 하나를 고르게 하는 시트.
  /// 취소하면(바깥 탭 등) null을 반환합니다.
  Future<ConcertResponse?> _pickConcertCandidate(
    List<ConcertResponse> candidates,
  ) {
    return showModalBottomSheet<ConcertResponse>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Text(
                '일치하는 공연이 여러 개예요. 하나를 선택해주세요.',
                style: TextStyle(
                  fontSize: context.sp(15),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            for (final candidate in candidates)
              ListTile(
                title: Text(
                  candidate.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${candidate.venue ?? '장소 미정'} · '
                  '${candidate.startDate.year}.'
                  '${candidate.startDate.month.toString().padLeft(2, '0')}.'
                  '${candidate.startDate.day.toString().padLeft(2, '0')}',
                ),
                onTap: () => Navigator.pop(context, candidate),
              ),
          ],
        ),
      ),
    );
  }

  /// 티켓 사진에 가격/좌석 정보가 없을 때, KOPIS 좌석 등급별 가격표 중
  /// 하나를 반드시 고르게 하는 시트 - 가격/좌석이 항상 채워지도록 바깥
  /// 탭·드래그·뒤로가기로는 못 닫고 항목을 선택해야만 닫힙니다.
  Future<PriceEntry?> _pickPriceEntry(List<PriceEntry> prices) {
    return showModalBottomSheet<PriceEntry>(
      context: context,
      backgroundColor: Colors.white,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => PopScope(
        canPop: false,
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Text(
                  '티켓에서 가격/좌석 정보를 찾지 못했어요.\n예매한 좌석을 선택해주세요.',
                  style: TextStyle(
                    fontSize: context.sp(15),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              for (final entry in prices)
                ListTile(
                  title: Text(
                    entry.seatType,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  trailing: Text('${_formatPrice(entry.price)}원'),
                  onTap: () => Navigator.pop(context, entry),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 천 단위 콤마(예: 160000 -> "160,000").
  String _formatPrice(int price) {
    return price.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
  }

  /// OCR이 뽑은 좌석 문구(예: "R석")와 같은 등급을 가격표에서 찾음(공백/대소문자
  /// 무시, 못 찾으면 부분 일치도 시도).
  PriceEntry? _matchTierBySeat(String seat, List<PriceEntry> tiers) {
    final target = seat.replaceAll(' ', '').toLowerCase();
    for (final tier in tiers) {
      if (tier.seatType.replaceAll(' ', '').toLowerCase() == target) return tier;
    }
    for (final tier in tiers) {
      final tierSeat = tier.seatType.replaceAll(' ', '').toLowerCase();
      if (target.contains(tierSeat) || tierSeat.contains(target)) return tier;
    }
    return null;
  }

  /// 결제 금액으로 좌석 등급을 추정. 수수료/배송비 때문에 결제액이 정가보다
  /// 조금 높은 게 보통이라, 정가가 결제액보다 큰 등급은 제외하고 남은 것 중
  /// 가장 가까운(=가장 비싼) 걸 고름. 전부 결제액보다 비싸면 포기(null).
  PriceEntry? _matchTierByPaidPrice(int paidPrice, List<PriceEntry> tiers) {
    final affordable = tiers.where((t) => t.price <= paidPrice).toList();
    if (affordable.isEmpty) return null;
    affordable.sort((a, b) => a.price.compareTo(b.price));
    return affordable.last; // 결제액 이하 중 가장 비싼(=가장 가까운) 등급
  }

  /// "YYYY-MM-DD" 문자열(백엔드 `shipping_date` 등)을 [DateTime]으로 변환합니다.
  /// 형식이 아니거나 없으면 null.
  DateTime? _parseYmd(String? yyyyMmDd) {
    if (yyyyMmDd == null) return null;
    return DateTime.tryParse(yyyyMmDd);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 티켓을 길게 누르면 삭제를 확인합니다.
  ///
  /// - 실제로 등록된 티켓(`info.ticketId`가 있는 것 — 백엔드에 저장된
  ///   카카오 티켓이든, 기기에만 저장된 게스트 티켓이든)이면 확인 후
  ///   [TicketService.deleteTicket]을 호출해 실제로 지웁니다(카카오는 서버,
  ///   게스트는 로컬 저장소).
  /// - 로컬 예시/디버그 티켓(등록된 적 없는 것)은 화면에서만 지웁니다.
  Future<void> _confirmDeleteTicket(TicketData ticket) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('티켓 삭제'),
        content: Text('"${ticket.title}" 티켓을 삭제할까요? 되돌릴 수 없어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    if (ticket.info?.ticketId == null) {
      // 등록된 적 없는 로컬 예시/디버그 티켓은 화면에서만 제거합니다.
      setState(() => _tickets.removeWhere((t) => t.id == ticket.id));
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    try {
      await _ticketService.deleteTicket(ticket.id);
      unawaited(TornTicketStore.instance.clear(ticket.id));
      if (!mounted) return;
      Navigator.pop(context);
      setState(() => _tickets.removeWhere((t) => t.id == ticket.id));
      _showSnack('티켓을 삭제했어요.');
    } on TicketNotFoundException {
      unawaited(TornTicketStore.instance.clear(ticket.id));
      if (!mounted) return;
      Navigator.pop(context);
      setState(() => _tickets.removeWhere((t) => t.id == ticket.id));
      _showSnack('이미 삭제된 티켓이에요.');
    } on ApiException catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      _showSnack('삭제에 실패했어요: ${e.message}');
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(context);
      _showSnack('알 수 없는 오류가 발생했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 페이지가 1장뿐이면(_totalPages<=1) "다음 페이지"가 존재하지 않으므로
    // null로 둡니다. 예전엔 (_currentPageIndex+1) % _totalPages가 1장일 때
    // 자기 자신(0 % 1 = 0)을 가리켜서, backPage가 frontPage와 완전히 같은
    // 티켓 목록을 같은 GlobalKey로 다시 그리다 충돌(Duplicate GlobalKey)이
    // 났습니다.
    final nextPageIndex = _totalPages > 1
        ? (_currentPageIndex + 1) % _totalPages
        : null;
    return Stack(
      children: [
        _buildDiaryPageFrameWithFlip(_currentPageIndex, nextPageIndex),
        _buildTransitionSpotlightOverlay(),
        // ===== [TEST-ONLY] 아래부터 다음 "===== [TEST-ONLY] 끝 =====" 줄까지
        // 통째로 지우면 완전히 제거되는 임시 테스트 탭입니다. =====
        _buildDebugTestTicketTab(),
        // ===== [TEST-ONLY] 끝 =====
      ],
    );
  }

  /// [TEST-ONLY] 왼쪽 아래에 붙는 테스트용 인덱스 탭. 누르면 실제 등록
  /// 플로우를 거치지 않고 더미 티켓을 바로 추가해, 다이어리 화면(D-day
  /// 배너/배송 전 카드의 "등록" 상태/중복 교체 등)이 실제 티켓 추가에
  /// 어떻게 반응하는지 곧바로 확인할 수 있습니다. 지울 때는 이 메서드와
  /// [_showDebugAddTestTicketFlow] 둘 다(또는 build()의 호출 한 줄만) 지우면
  /// 됩니다 — 다른 코드는 이 둘을 참조하지 않습니다.
  Widget _buildDebugTestTicketTab() {
    return Positioned(
      left: 0,
      bottom: 60,
      child: GestureDetector(
        onTap: () => unawaited(_showDebugAddTestTicketFlow()),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.redAccent.withValues(alpha: 0.85),
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(8),
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(2, 2),
              ),
            ],
          ),
          child: const Text(
            'TEST',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 11,
              letterSpacing: 1,
            ),
          ),
        ),
      ),
    );
  }

  /// [TEST-ONLY] "배송 전"/"배송 후" 선택 -> 날짜 입력 -> 더미 티켓 삽입까지의
  /// 흐름. 반복 테스트를 편하게 하기 위해, 실제 등록 때와 달리 "배송 전"
  /// 중복 교체는 하지 않고(날짜/기존 항목과 무관하게 항상 새로 추가) 매번
  /// 새 [TicketData]를 맨 앞에 그대로 끼워 넣습니다. 백엔드 호출이 없어
  /// 앱을 완전히 종료하면(정적 [_tickets]가 메모리에서 사라지므로) 자동으로
  /// 없어집니다.
  Future<void> _showDebugAddTestTicketFlow() async {
    final bool? isBeforeDelivery = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                '[TEST] 어떤 상태의 티켓을 추가할까요?',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.local_shipping_outlined,
                color: Colors.redAccent,
              ),
              title: const Text('배송 전'),
              subtitle: const Text('배송일자를 고릅니다'),
              onTap: () => Navigator.pop(context, true),
            ),
            ListTile(
              leading: const Icon(
                Icons.confirmation_num_outlined,
                color: Colors.redAccent,
              ),
              title: const Text('배송 후'),
              subtitle: const Text('공연 날짜를 고릅니다(미래면 공연 전, 과거면 공연 후)'),
              onTap: () => Navigator.pop(context, false),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (isBeforeDelivery == null || !mounted) return;

    final DateTime? pickedDate = await _pickDebugTestDateByTyping(
      isBeforeDelivery ? '배송일자' : '공연 날짜',
    );
    if (pickedDate == null || !mounted) return;

    const testInfoBase = TicketInfo(
      concertName: '테스트 공연',
      venueName: '테스트',
      price: '0',
      seat: '테스트',
      vendorName: '테스트',
    );
    final TicketData testTicket = isBeforeDelivery
        ? TicketData(
            title: '테스트 공연',
            status: TicketStatus.beforeDelivery,
            info: testInfoBase.copyWith(deliveryDate: pickedDate),
          )
        : TicketData(
            title: '테스트 공연',
            status: pickedDate.isAfter(DateTime.now())
                ? TicketStatus.beforeConcert
                : TicketStatus.afterConcert,
            info: testInfoBase.copyWith(date: pickedDate),
          );

    // 반복 테스트 편의를 위해 배송 전 중복 교체 없이 항상 새로 추가합니다.
    setState(() => _tickets.insert(0, testTicket));
    _showSnack('[TEST] 테스트 티켓이 추가되었습니다 (${_debugStatusLabel(testTicket.status)}).');
  }

  /// [TEST-ONLY] 달력 대신 숫자만 입력받아 날짜를 만듭니다. "2026826"처럼
  /// 입력하면 입력 중에도 실시간으로 "2026년 8월 26일"로 보이도록
  /// [_DebugYmdInputFormatter]가 표시 문자열을 다시 그려줍니다. 연/월/일이
  /// 모두 채워지지 않은 채 확인을 누르면 안내만 하고 닫지 않습니다.
  Future<DateTime?> _pickDebugTestDateByTyping(String label) {
    final controller = TextEditingController();
    return showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        void submit() {
          final parsed = _parseDebugYmdDigits(controller.text);
          if (parsed == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('연/월/일을 모두 입력해주세요. 예: 2026826')),
            );
            return;
          }
          Navigator.pop(context, parsed);
        }

        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '[TEST] $label 입력 (숫자만)',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '예: 2026826 -> 2026년 8월 26일',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [const _DebugYmdInputFormatter()],
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'YYYYMD',
                    ),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: submit,
                      child: const Text('확인'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// [TEST-ONLY] 완료 스낵바에 보여줄 상태 한글 라벨.
  String _debugStatusLabel(TicketStatus status) {
    switch (status) {
      case TicketStatus.beforeDelivery:
        return '배송 전';
      case TicketStatus.beforeConcert:
        return '공연 전';
      case TicketStatus.afterConcert:
        return '공연 후';
      case TicketStatus.error:
        return '오류';
    }
  }

  /// 전환 중인 티켓을 제외한 화면 전체를 어둡게 덮고, 그 위에 전환 중인 티켓을
  /// 원래 위치(Rect) 그대로 다시 그려서(밝게 유지) 강조합니다.
  Widget _buildTransitionSpotlightOverlay() {
    final id = _transitionSpotlightIds.isEmpty
        ? null
        : _transitionSpotlightIds.first;
    // Positioned.fromRect는 이 Stack(=DiaryScreen 자기 자신) 기준 좌표를 쓰므로,
    // 전역(global) 좌표를 DiaryScreen 자신의 위치만큼 보정해줍니다.
    Rect? rect;
    if (id != null) {
      final globalRect = _globalRectOf(_highlightKeyFor(id));
      final selfBox = context.findRenderObject() as RenderBox?;
      if (globalRect != null && selfBox != null && selfBox.hasSize) {
        rect = globalRect.shift(-selfBox.localToGlobal(Offset.zero));
      }
    }

    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _isSpotlightActive ? 1.0 : 0.0,
          duration: _spotlightDimFadeDuration,
          curve: Curves.easeInOut,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.5)),
              ),
              if (rect != null && id != null)
                Positioned.fromRect(
                  rect: rect,
                  child: _buildSpotlightTicketVisual(id),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 강조 오버레이에 다시 그릴, 상호작용 없는(비-키) 티켓 시각화.
  /// 실제 티켓 위젯을 그대로 재사용하면 [TicketData.overlayKey]가 화면에
  /// 두 번 마운트되어 GlobalKey 충돌이 나므로, 여기서는 새 key로 그립니다.
  ///
  /// 강조(스포트라이트)가 떠 있는 동안에는 화면에서 실제로 보이는 게 이
  /// 위젯뿐이므로(나머지는 어두운 오버레이에 가려짐), 실제 리스트 항목과
  /// 똑같이 [_promotionFadeDuration]짜리 크로스페이드를 여기서도 재생해야
  /// "천천히 겹쳐 보이는" 전환이 실제로 눈에 보입니다.
  Widget _buildSpotlightTicketVisual(String id) {
    final ticket = _tickets.firstWhere(
      (t) => t.id == id,
      orElse: () => TicketData(title: '', status: TicketStatus.beforeConcert),
    );

    return AnimatedSwitcher(
      duration: _promotionFadeDuration,
      child: KeyedSubtree(
        key: ValueKey(ticket.status),
        child: ticket.status == TicketStatus.afterConcert
            ? _buildTicketPocket(
                child: _buildTicketAfterConcert(
                  context,
                  title: ticket.title,
                  info: ticket.info,
                  overlayKey: GlobalKey(),
                  posterOverlayKey: GlobalKey(),
                  vibrate: !_transitionSpotlightIds.contains(ticket.id),
                  initiallyRevealed: ticket.tornRevealed,
                ),
              )
            : _buildTicketPocket(
                child: _buildTicketBeforeConcert(
                  title: ticket.title,
                  info: ticket.info,
                ),
              ),
      ),
    );
  }

  /// 플립 애니메이션에 쓰이는 페이지 잎 한 장. 프레임 전체 크기를 받아,
  /// 페이지 종이(프레임 3번 레이어와 같은 여백/10% 가로 확대)를 담습니다.
  ///
  /// "다이어리" 활성 탭은 여기 포함하지 않습니다 — 탭이 회전축(pivotX)에서
  /// 멀리 떨어져 있다 보니, 페이지 전체를 3D로 휘게 만드는 행별 메시
  /// 계산에 같이 포함되면 두 조각으로 쪼개져 보이는 문제가 있었습니다.
  /// 대신 [DiaryPageFlipper.activeTab]으로 따로 넘겨서, 메시가 아닌 단순
  /// 회전으로만 페이지와 같이 넘어가도록 합니다.
  Widget _buildFlipLeaf(int pageIndex) {
    // 페이지 종이. 여백/가로 10% 확대는 [DiaryPageFrame]의 기본 페이지
    // 배치(defaultPageTop/Bottom/Left/Right/WidthFactor)와 동일해야
    // 합니다. 그림자는 여기 없습니다 — 페이지가 넘어갈 때 이 위젯째로
    // 스냅샷을 찍어 3D로 휘게 만드는데, boxShadow가 그 안에 같이
    // 있으면 휘어지는 메시를 따라 그림자도 왜곡돼(원래 가장자리에만
    // 있던 그림자가 대각선으로 크게 번진 것처럼 보임) 정지 상태와
    // 다르게 보였습니다. 대신 [DiaryPageFlipper]가 이 위치에 항상
    // 왜곡 없는 정적 그림자를 별도로 깔아둡니다.
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        Positioned(
          top: DiaryPageFrame.defaultPageTop,
          bottom: DiaryPageFrame.defaultPageBottom,
          left: DiaryPageFrame.defaultPageLeft,
          right: DiaryPageFrame.defaultPageRight,
          child: FractionallySizedBox(
            widthFactor: DiaryPageFrame.defaultPageWidthFactor,
            child: LayoutBuilder(
              builder: (context, constraints) => Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: _paperColor,
                  borderRadius: DiaryPageFrame.defaultPageBorderRadius,
                ),
                child: _buildPageContent(pageIndex, constraints),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 페이지와 함께 넘어가는 "다이어리" 활성 탭. [DiaryPageFlipper.activeTab]
  /// 으로 넘겨서 단순 회전으로만 종이와 같이 움직이게 합니다.
  ///
  /// 이 위젯은 [DiaryPageFrame]의 생성자 인자로 쓰일 트리를 여기(diary_screen
  /// 자신의 State.context)에서 미리 만들지만, 실제로는 나중에
  /// [DiaryPageFrame]이 세운 [DiaryFrameScale] 서브트리 안(overlayMainPage
  /// 경유)에 마운트됩니다. 그래서 [DiaryFrameScale]을 조회하려면(=다른
  /// 고정 탭들과 같은 배율/여백 확장을 적용하려면) 지금 이 context가 아니라,
  /// 실제로 트리에 들어간 뒤의 context가 필요합니다 — [Builder]로 그 시점의
  /// context를 받아 [DiaryPageFrame.buildScaledSideTab]에 넘깁니다(다른
  /// 고정 탭들이 [DiaryPageFrame._buildFrameStack]에서 쓰는 것과 동일한
  /// 로직이라, 크기·여백 확장 동작이 완전히 같아집니다).
  Widget? _buildActiveTab(List<DiarySideTabSpec> tabs) {
    if (tabs.isEmpty) return null;
    final tab = tabs.first;
    return Builder(
      builder: (context) {
        final frameScale = DiaryFrameScale.maybeWidgetOf(context);
        final scale = frameScale?.scale ?? 1.0;
        final marginEachSide = frameScale?.marginEachSide ?? 0.0;
        return DiaryPageFrame.buildScaledSideTab(tab, scale, marginEachSide);
      },
    );
  }

  Widget _buildDiaryPageFrameWithFlip(int pageIndex, int? nextPageIndex) {
    final prevPageIndex = pageIndex > 0 ? pageIndex - 1 : null;
    final allTabs = buildDiarySideTabs(context, active: DiaryTab.diary);
    // "다이어리" 탭만 페이지 잎에 붙여서 함께 넘어가고, 소식/결산/설정은
    // 프레임에 고정해 넘김과 무관하게 제자리를 지킵니다.
    final diaryTab = allTabs.where((t) => t.isActive).toList(growable: false);
    final fixedTabs = allTabs.where((t) => !t.isActive).toList(growable: false);
    return DiaryPageFrame(
      isTabRoot: _currentPageIndex == pageIndex && pageIndex == 0,
      scaleOverride: widget.frameScaleOverride,
      marginEachSideOverride: widget.frameMarginOverride,
      sideTabs: fixedTabs,
      animateMainPage: true,
      // 잎에 다이어리 탭까지 포함하려면 오버레이가 페이지 박스보다 넓은
      // 프레임 전체를 차지해야 합니다. 회전축(pivotX)은 페이지 종이의
      // 왼쪽 모서리(= 30 - 가로 10% 확대로 늘어난 절반) 위치입니다.
      overlayMainPageFullFrame: true,
      // 페이지 넘김과 같은 속도로 바인더 링이 오른쪽부터 사라졌다가
      // 넘김이 끝나면 다시 나타나게 합니다.
      overlayFlipProgress: _flipAnimating,
      overlayMainPage: LayoutBuilder(
        builder: (context, constraints) => DiaryPageFlipper(
          key: ValueKey('flipper_$_currentPageIndex'),
          pivotX: 30 - (constraints.maxWidth - 75) * 0.05,
          // 오른쪽 45(=pageRight)는 프레임에 고정된 소식/결산/설정 탭
          // 자리라, 스와이프 제스처가 그 탭들의 탭(누름) 이벤트를 가로채지
          // 않도록 제외합니다.
          dragExclusionRight: 45,
          flipProgressNotifier: _flipAnimating,
          activeTab: _buildActiveTab(diaryTab),
          frontPage: _buildFlipLeaf(pageIndex),
          // 다음 페이지가 없으면(nextPageIndex==null) frontPage와 같은
          // 티켓을 같은 GlobalKey로 다시 그리지 않도록 빈 페이지를
          // 넣습니다. 이 상태에서는 onFlipForward도 null이라 실제로
          // 넘어가 보이지도 않습니다.
          backPage: nextPageIndex == null
              ? const SizedBox.shrink()
              : _buildFlipLeaf(nextPageIndex),
          // 첫 페이지가 아니면 오른쪽 스와이프로 이전 페이지로 돌아갑니다.
          // prevPage(이전 페이지)와 frontPage(현재 페이지)는 서로 다른 티켓
          // 목록이라 GlobalKey가 겹치지 않고, backPage와는 DiaryPageFlipper가
          // 넘김 방향별로 한쪽만 트리에 올리므로 동시에 마운트되지 않습니다.
          prevPage: prevPageIndex == null
              ? null
              : _buildFlipLeaf(prevPageIndex),
          onFlipForward: _currentPageIndex < _totalPages - 1
              ? () {
                  final now = DateTime.now();
                  if (now.difference(_lastFlipTime) < _flipCooldown) return;
                  _lastFlipTime = now;
                  setState(() => _currentPageIndex++);
                }
              : null,
          onFlipBackward: prevPageIndex == null
              ? null
              : () {
                  final now = DateTime.now();
                  if (now.difference(_lastFlipTime) < _flipCooldown) return;
                  _lastFlipTime = now;
                  setState(() => _currentPageIndex--);
                },
          flipUpward: false,
        ),
      ),
      child: const SizedBox.shrink(),
    );
  }

  Widget _buildAddTicketArea(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _isAddTicketExpanded
          ? GestureDetector(
              key: const ValueKey('add_ticket_options'),
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: _buildAddTicketOptions(context),
            )
          : PressableScale(
              key: const ValueKey('add_ticket_button'),
              onTap: () => setState(() => _isAddTicketExpanded = true),
              child: _buildAddTicketButton(),
            ),
    );
  }

  Widget _buildAddTicketOptions(BuildContext context) {
    // 다른 티켓들과 같은 비닐 포켓 프레임 안에 표시합니다.
    return _buildTicketPocket(
      child: Row(
        children: [
          Expanded(
            child: AddTicketOption(
              icon: Icons.photo_camera_outlined,
              label: '카메라',
              onTap: _startCameraScan,
            ),
          ),
          Container(
            width: 1,
            margin: const EdgeInsets.symmetric(vertical: 14),
            color: Colors.black.withValues(alpha: 0.18),
          ),
          Expanded(
            child: AddTicketOption(
              icon: Icons.photo_library_outlined,
              label: '갤러리',
              onTap: _pickFromGalleryAndAnalyze,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageContent(int pageIndex, BoxConstraints constraints) {
    final bool isFirstPage = pageIndex == 0;
    final pageTickets = _ticketsForPage(pageIndex);

    // 카드 높이는 고정값이 아니라, 실제 렌더링 너비(가로 Padding 25*2를 뺀 값)를
    // 기준으로 _ticketAspectRatio에서 역산합니다(버튼도 티켓과 같은 비율·높이를 씀).
    // _buildTicketPocket이 요청하는 너비(*1.1)는 Center가 준 느슨한 제약의
    // 최대치(=이 itemWidth)로 다시 clamp되어 실제로는 1.1배가 적용되지
    // 않으므로(실측 확인됨), 여기서도 배율 없이 그대로 역산해야 실제
    // 렌더링 높이와 맞아떨어집니다.
    final double itemWidth = constraints.maxWidth - 50;
    final double itemHeight = itemWidth / _ticketAspectRatio;

    // 첫 페이지: 버튼 1개 + 티켓 3개(총 4개, 모두 같은 높이) + 항목 사이 간격 3곳
    // 이후 페이지: 티켓 4개(모두 같은 높이) + 항목 사이 간격 3곳
    final double targetTotalHeight = isFirstPage
        ? (itemHeight * (_firstPageTicketCapacity + 1)) +
              (_ticketSpacing * _firstPageTicketCapacity)
        : (itemHeight * _otherPageTicketCapacity) +
              (_ticketSpacing * (_otherPageTicketCapacity - 1));
    // 이 위젯이 그리는 크림색 종이(Container)는 DiaryPageFrame이 이미
    // defaultPageTop/Bottom(10/20)만큼 바깥 프레임에서 잘라낸 "종이 안쪽"
    // 영역 전체를 자기 크기로 그대로 씁니다 - 즉 constraints(=이 함수의
    // maxHeight)가 곧 사용자 눈에 보이는 종이의 실제 높이입니다. 사용자가
    // 비교하는 "위/아래 여백"은 바로 이 종이의 위 가장자리~첫 티켓,
    // 마지막 티켓~종이의 아래 가장자리이므로, 프레임 바깥(눈에 보이지
    // 않는) 위/아래 비대칭과는 무관하게 이 종이 안에서 단순히 반씩
    // 나누기만 하면 됩니다. (예전엔 바깥 프레임의 10/20 비대칭까지
    // 보정하려다 오히려 눈에 보이는 종이 안쪽 여백이 위로 쏠렸습니다.)
    final double fixedTopPadding =
        (constraints.maxHeight - targetTotalHeight) / 2;

    return AbsorbPointer(
      absorbing: _interactionLocked,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _isAddTicketExpanded
            ? () => setState(() => _isAddTicketExpanded = false)
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 25),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start, // 상단 고정 시작
            children: [
              SizedBox(
                height: fixedTopPadding.clamp(20.0, double.infinity),
                // 첫 페이지에서만, 계산된 상단 여백 안에 다음 공연 D-day를
                // 표시합니다(여백 높이 자체는 그대로라 페이지 레이아웃/
                // 위아래 균형에는 영향이 없습니다).
                child: isFirstPage ? _buildUpcomingDDayBanner(context) : null,
              ), // 계산된 고정 상단 여백
              if (isFirstPage) ...[
                _buildAddTicketArea(context),
                const SizedBox(
                  height: _ticketSpacing,
                ), // 추가 버튼과 리스트 사이 간격(티켓 간격과 동일)
              ],
              if (pageTickets.isEmpty && isFirstPage)
                // 티켓이 없을 때도 자리를 유지하기 위한 투명 박스 또는 안내 문구
                SizedBox(
                  height: 300,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.airplane_ticket_outlined,
                          size: 60,
                          color: Colors.black.withValues(alpha: 0.1),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          "티켓을 스캔해보세요!",
                          style: TextStyle(
                            color: Colors.black.withValues(alpha: 0.3),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: pageTickets.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: _ticketSpacing),
                  itemBuilder: (context, index) {
                    final ticket = pageTickets[index];
                    // 공연 시간이 지나 "공연 전" -> "공연 후"로 자동 전환될 때,
                    // 같은 자리에서 자연스럽게 페이드 인아웃되도록 상태를 key로 씁니다.
                    // 바깥의 KeyedSubtree는 전환 강조 오버레이가 이 티켓의 화면
                    // 위치(Rect)를 찾을 수 있도록 붙여둔 것입니다.
                    return KeyedSubtree(
                      key: _highlightKeyFor(ticket.id),
                      child: GestureDetector(
                        onLongPress: _isAddTicketExpanded
                            ? null
                            : () => unawaited(_confirmDeleteTicket(ticket)),
                        child: AnimatedSwitcher(
                          duration: _promotionFadeDuration,
                          child: KeyedSubtree(
                            key: ValueKey(ticket.status),
                            // [백엔드 수정]
                            // itemBuilder가 주는 context를 그대로 넘김.
                            child: _buildTicketByStatus(context, ticket),
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTicketByStatus(BuildContext context, TicketData ticket) {
    switch (ticket.status) {
      case TicketStatus.beforeDelivery:
        return _buildTicketPocket(
          child: TicketFlipCard(
            enabled: !_isAddTicketExpanded,
            perspective: 0.00055,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(8),
            front: _buildTicketBeforeDelivery(
              title: ticket.title,
              info: ticket.info,
            ),
            back: _buildTicketBeforeDeliveryBack(info: ticket.info),
          ),
        );
      case TicketStatus.beforeConcert:
        final isDue = _isDueForPromotion(ticket);
        final ticketWidget = PressableScale(
          onTap: _isAddTicketExpanded
              ? null
              : isDue
              // 공연 시간이 이미 지난 티켓은 눌렀을 때 "공연 후"로의 전환
              // 애니메이션을 재생합니다(공연이 끝났으니 상세 오버레이 대신).
              ? () => unawaited(_runTicketPromotionAnimation(ticket.id))
              : () async {
                  final startRect = _globalRectOf(ticket.overlayKey);
                  if (startRect == null) return;

                  // [백엔드 수정]
                  // 오버레이가 떠있는 동안 리스트의 진짜 티켓을 숨겨서
                  // 복사본(collapsedTicket)과 겹쳐 보이지 않도록 함.
                  setState(() => _overlayHiddenRegionKey = ticket.overlayKey);
                  await ConcertBeforeOverlay.show(
                    context,
                    startRect: startRect,
                    // startRect 크기로 그대로 채움.
                    collapsedTicket: _buildTicketDecoration(
                      child: _buildTicketBeforeConcert(
                        title: ticket.title,
                        info: ticket.info,
                      ),
                    ),
                    concertTitle: ticket.title,
                    ticketInfo: ticket.info,
                    issueNumber: _issueNumberForIndex(
                      _tickets.indexWhere((t) => t.id == ticket.id),
                    ),
                    // [백엔드 수정]
                    // 이 리스트에서 쓰이는 배율을 그대로 넘김.
                    frameScale:
                        DiaryFrameScale.maybeOf(context) ??
                        diaryScaleFromMediaQuery(context),
                  );
                  if (mounted) setState(() => _overlayHiddenRegionKey = null);
                },
          child: _hideWhileOverlayOpen(
            regionKey: ticket.overlayKey,
            child: _buildTicketPocket(
              contentKey: ticket.overlayKey,
              child: _buildTicketBeforeConcert(
                title: ticket.title,
                info: ticket.info,
              ),
            ),
          ),
        );
        return isDue ? SparkleHighlight(child: ticketWidget) : ticketWidget;
      case TicketStatus.afterConcert:
        return _buildTicketPocket(
          child: _buildTicketAfterConcert(
            context,
            title: ticket.title,
            info: ticket.info,
            overlayKey: ticket.overlayKey,
            posterOverlayKey: ticket.posterOverlayKey,
            // 방금 "공연 전 -> 공연 후"로 전환된 티켓은, 전환 애니메이션이
            // 완전히 끝날 때까지(_transitionSpotlightIds에서 빠질 때까지)
            // 진동을 멈춰뒀다가 그 이후에 시작합니다.
            vibrate: !_transitionSpotlightIds.contains(ticket.id),
            // 이전에 이미 뜯어둔 티켓이면(다이어리 화면을 나갔다 왔어도) 다시
            // 뜯긴 상태로 보여주고, 처음 뜯는 순간에는 티켓 데이터에 기록해서
            // 이후에도 계속 뜯긴 채로 유지되게 합니다.
            initiallyRevealed: ticket.tornRevealed,
            onInfoChanged: (updated) => setState(() => ticket.info = updated),
            onTorn: () {
              setState(() => ticket.tornRevealed = true);
              // 서버(게스트는 로컬 저장소)에 torn_at을 기록해 재설치/다른
              // 기기에서도 유지되게 합니다. TornTicketStore(기기 로컬)에도
              // 그대로 남겨서, 이 요청이 네트워크 실패로 못 나가도 최소한
              // 이 기기에서는 뜯긴 상태가 유지됩니다.
              // 서버 동기화는 최선 노력(best-effort)입니다 — 실패해도 이미
              // 화면상 연출은 끝났고 TornTicketStore가 로컬 유지를
              // 보장하므로, ignore()로 조용히 무시합니다.
              _ticketService
                  .updateTicket(ticket.id, tornAt: DateTime.now())
                  .ignore();
              unawaited(TornTicketStore.instance.markTorn(ticket.id));
            },
          ),
        );
      case TicketStatus.error:
        // 오류 시에는 '배송전 티켓' 디자인을 레퍼런스로 보여줍니다.
        return _buildTicketPocket(
          child: Opacity(
            opacity: 0.8,
            child: _buildTicketBeforeDelivery(title: ticket.title),
          ),
        );
    }
  }

  Widget _buildAddTicketButton() {
    // 다른 티켓들처럼 비닐 포켓 프레임 안에, 실제 티켓 자리를 대신하는
    // 네모난 박스(흰 배경 카드)를 하나 더 넣어서 "포켓 안에 티켓이 들어있는"
    // 모양을 그대로 따라갑니다.
    //
    // [백엔드 수정]
    // context.sp(26)가 DiaryFrameScale을 못 찾던 버그 - Builder로 감싸서
    // DiaryPageFrame 하위 context로 바꿈.
    return _buildTicketPocket(
      child: Builder(
        builder: (context) => Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              "티켓  추가",
              style: TextStyle(
                fontSize: context.sp(26),
                fontWeight: FontWeight.bold,
                color: Colors.black87,
                letterSpacing: 4.0,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // [백엔드 수정]
  // 실제로 그려지는 티켓의 장식(테두리+그라데이션+패딩)만 따로 뺌
  // 크기는 정하지 않고 부모가 준 만큼 그대로 채움.
  Widget _buildTicketDecoration({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.8),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 5,
            offset: const Offset(2, 2),
          ),
        ],
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.6),
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.2),
          ],
        ),
      ),
      child: Padding(padding: const EdgeInsets.all(10.0), child: child),
    );
  }

  Widget _buildTicketPocket({required Widget child, Key? contentKey}) {
    // 배치 공간(칸 크기)은 그대로 두고, 실제로 그려지는 티켓만 10% 더
    // 크게 키웁니다. Transform.scale 대신 실제 레이아웃 너비를 10% 넓혀서
    // (SizedBox+AspectRatio) 안의 글씨가 픽셀 단위로 늘어나지 않고 정상
    // 크기로 다시 배치되도록 합니다. 늘어난 만큼은 칸 사이 간격 쪽으로
    // 살짝 걸칩니다. (이 10% 확대는 _buildPageContent의 높이 계산에도
    // 반영되어 있어야 합니다 — itemHeight 계산 참고.)
    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: SizedBox(
            key: contentKey,
            width: constraints.maxWidth * 1.1,
            child: AspectRatio(
              aspectRatio: _ticketAspectRatio,
              child: _buildTicketDecoration(child: child),
            ),
          ),
        );
      },
    );
  }

  /// 배송 예정일 기준 D-day 텍스트. 아직 배송일 정보가 없으면 'D-00'을 보여줍니다.
  String _deliveryDDayLabel(DateTime? date) {
    if (date == null) return 'D-00';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = target.difference(today).inDays;
    if (diff > 0) return 'D-$diff';
    if (diff == 0) return 'D-DAY';
    return 'D+${-diff}';
  }

  /// 배송 예정일 당일이 되었거나 지났으면(등록 가능 상태) true.
  bool _isDeliveryDue(DateTime? date) {
    if (date == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    return !target.isAfter(today);
  }

  String _formatDeliveryDate(DateTime? date) {
    if (date == null) return '0000.00.00';
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }

  /// 등록된 티켓들 중 앞으로 시작할 공연이 가장 빠른 "공연 전" 티켓.
  /// 없으면(등록된 공연이 없거나 전부 지난 공연이면) null.
  TicketData? _nearestUpcomingTicket() {
    final now = DateTime.now();
    TicketData? nearest;
    for (final ticket in _tickets) {
      if (ticket.status != TicketStatus.beforeConcert) continue;
      final date = ticket.info?.date;
      if (date == null || !date.isAfter(now)) continue;
      if (nearest == null || date.isBefore(nearest.info!.date!)) {
        nearest = ticket;
      }
    }
    return nearest;
  }

  /// 첫 페이지 상단 여백에 표시하는, 가장 빠르게 시작하는 공연의 D-day+제목.
  /// 다가오는 공연이 없으면 빈 공간을 그대로 둡니다.
  ///
  /// 이 배너가 차지하는 높이 자체는 상/하단 여백을 맞추는 계산([_buildPageContent]의
  /// fixedTopPadding)에 전혀 영향을 주지 않도록 그 여백 칸 안에 그대로
  /// 끼워 넣습니다 - 다만 [Center]로 칸 한가운데 두면, 글씨가 넓은 빈
  /// 공간의 중간에 떠 있어서 "위쪽 여백에 뭔가 들어있다"는 인상이 강해져
  /// 실제로는 위/아래 여백 높이가 같아도 위쪽이 더 커 보였습니다. 페이지
  /// 맨 위에 붙는 얇은 헤더처럼 보이도록 위쪽에 살짝만 띄워 붙여서, 나머지
  /// 대부분은 아래쪽처럼 완전히 빈 여백으로 보이게 합니다.
  Widget _buildUpcomingDDayBanner(BuildContext context) {
    final nearest = _nearestUpcomingTicket();
    if (nearest == null) return const SizedBox.shrink();
    final dDay = _deliveryDDayLabel(nearest.info!.date);
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(top: context.rs(10)),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '$dDay  ${nearest.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.sp(13),
              fontWeight: FontWeight.w800,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTicketBeforeDelivery({required String title, TicketInfo? info}) {
    final dDayLabel = _deliveryDDayLabel(info?.deliveryDate);
    final isRegisterReady = _isDeliveryDue(info?.deliveryDate);
    final vendorLabel = isRegisterReady
        ? '등록'
        : ((info?.vendorName?.isNotEmpty ?? false) ? info!.vendorName! : '예매처');

    // 배송 예정일이 되면(isRegisterReady) 실물 티켓을 등록하라는 안내
    // 문구를 함께 보여주고, "티켓 추가" 버튼을 거치지 않고도 이 카드를
    // 직접 눌러 바로 카메라 스캔으로 실물 티켓을 등록할 수 있게 합니다.
    final readyMessage = isRegisterReady ? '배송이 시작되었습니다!' : null;
    final onReadyTap = isRegisterReady && !_isAddTicketExpanded
        ? () => _startCameraScan()
        : null;

    // 뜯는 부분(스티커/라벨)을 카드 왼쪽으로, 공연 정보(포스터/D-day)를
    // 오른쪽으로 — 바깥쪽 모서리 둥글림도 함께 뒤집는다.
    if (_usePosterTicketDesign) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onReadyTap,
        child: Row(
          children: [
            Expanded(
              flex: 13,
              child: _TicketStub(
                label: vendorLabel,
                labelColor: isRegisterReady ? const Color(0xFF16A34A) : null,
                radiusOnLeft: true,
              ),
            ),
            Container(width: 1, color: Colors.grey.shade400),
            Expanded(
              flex: 27,
              child: _PosterTicketFace(
                title: title,
                info: info,
                bigCenterText: dDayLabel,
                centerMessage: readyMessage,
                radiusOnRight: true,
              ),
            ),
          ],
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onReadyTap,
      child: Row(
        children: [
          Expanded(
            flex: 13,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
              ),
              child: Center(
                child: Text(
                  vendorLabel,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.sp(12),
                    color: isRegisterReady
                        ? const Color(0xFF16A34A)
                        : Colors.black54,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          Container(width: 1, color: Colors.grey.shade400),
          Expanded(
            flex: 27,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.horizontal(right: Radius.circular(8)),
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: context.sp(12),
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                  const Spacer(),
                  Center(
                    child: Text(
                      dDayLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: context.sp(18),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (readyMessage != null) ...[
                    const SizedBox(height: 4),
                    Center(
                      child: Text(
                        readyMessage,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.sp(11),
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF16A34A),
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTicketBeforeDeliveryBack({TicketInfo? info}) {
    final date = _formatDeliveryDate(info?.deliveryDate);
    final venue = '알 수 없는 공연장';
    const time = '00:00';
    const seat = 'A구역 00열 00번';
    const price = '0';

    Widget infoRow(String label, String value, {int maxLines = 1}) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            // [백엔드 수정]
            // 폰트와 같은 배율로 같이 커지도록 context.rs()로 바꿈(고정 36px이라
            // 태블릿 등에서 "공연장" 라벨이 "공연\n장"으로 줄바꿈되던 문제).
            width: context.rs(36),
            child: Text(
              label,
              style: TextStyle(
                fontSize: context.sp(11),
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.sp(12),
                fontWeight: FontWeight.w600,
                color: Colors.black87,
                height: 1.15,
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '공연 정보',
            style: TextStyle(
              fontSize: context.sp(12),
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              infoRow('날짜', date),
                              const SizedBox(height: 4),
                              infoRow('시간', time),
                              const SizedBox(height: 4),
                              infoRow('공연장', venue, maxLines: 2),
                            ],
                          ),
                        ),
                        Container(
                          width: 1,
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          color: Colors.black.withValues(alpha: 0.10),
                        ),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              infoRow('좌석', seat, maxLines: 2),
                              const SizedBox(height: 4),
                              infoRow('가격', price),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTicketBeforeConcert({required String title, TicketInfo? info}) {
    // "입장 티켓" 라벨을 카드 왼쪽으로 옮기고, 공연 정보(포스터/제목)를
    // 오른쪽으로 옮김 — 바깥쪽 모서리 둥글림도 함께 뒤집는다.
    if (_usePosterTicketDesign) {
      return Row(
        children: [
          const Expanded(
            flex: 13,
            child: _TicketStub(label: '입장 티켓', radiusOnLeft: true),
          ),
          Container(width: 1, color: Colors.grey.shade400),
          Expanded(
            flex: 27,
            child: _PosterTicketFace(title: title, info: info, radiusOnRight: true),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          flex: 13,
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
            ),
            child: Center(
              child: Text(
                '입장 티켓',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.sp(12),
                  fontWeight: FontWeight.w800,
                  color: Colors.black.withValues(alpha: 0.55),
                ),
              ),
            ),
          ),
        ),
        Container(width: 1, color: Colors.grey.shade400),
        Expanded(
          flex: 27,
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.horizontal(right: Radius.circular(8)),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: context.sp(12),
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: context.sp(22),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTicketAfterConcert(
    BuildContext context, {
    required String title,
    TicketInfo? info,
    required GlobalKey overlayKey,
    required GlobalKey posterOverlayKey,
    bool vibrate = true,
    bool initiallyRevealed = false,
    VoidCallback? onTorn,
    ValueChanged<TicketInfo>? onInfoChanged,
  }) {
    // 입장 티켓을 뜯은 뒤에는, 티켓 어디를 눌러도 "공연 후" 페이지가 뜹니다.
    // (예전의 뜯긴 왼쪽 = "공연전" 바로가기/공연 전 페이지 진입은 제거.)
    Future<void> openAfter() async {
      final startRect = _globalRectOf(posterOverlayKey);
      if (startRect == null) return;
      setState(() => _overlayHiddenRegionKey = posterOverlayKey);
      await ConcertAfterOverlay.show(
        context,
        startRect: startRect,
        collapsedTicket: _buildAfterConcertPosterFace(
          title: title,
          info: info,
          radiusOnRight: true,
        ),
        concertTitle: title,
        ticketInfo: info,
        onTicketInfoChanged: onInfoChanged,
        // [백엔드 수정] 이 리스트에서 쓰이는 배율을 그대로 넘김.
        frameScale:
            DiaryFrameScale.maybeOf(context) ??
            diaryScaleFromMediaQuery(context),
      );
      if (mounted) setState(() => _overlayHiddenRegionKey = null);
    }

    // 뜯는 부분(관람 완료 라벨/뜯긴 뒤 스텁)을 카드 왼쪽으로, 공연 정보(포스터/
    // 제목)를 오른쪽으로 — 바깥쪽 모서리 둥글림도 함께 뒤집는다.
    return Row(
      children: [
        Expanded(
          flex: 13,
          child: EntryTicketTearPiece(
            enabled: !_isAddTicketExpanded,
            vibrate: vibrate,
            initiallyRevealed: initiallyRevealed,
            onTorn: onTorn,
            // 뜯기 전: 다른 티켓 왼쪽 칸과 동일한 디자인 + "관람 완료" 라벨
            front: _usePosterTicketDesign
                ? const _TicketStub(label: '관람 완료', radiusOnLeft: true)
                : DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.horizontal(
                        left: Radius.circular(8),
                      ),
                    ),
                    child: Center(
                      child: Text(
                        '관람 완료',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.sp(12),
                          fontWeight: FontWeight.w800,
                          color: Colors.black.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ),
            // 뜯긴 뒤: "공연전" 텍스트/바로가기 없이, 흰 배경도 없이 빈(투명)
            // 영역만 남긴다. 눌러도 (오른쪽 포스터와 동일하게) 공연 후 페이지가 뜬다.
            revealed: _hideWhileOverlayOpen(
              regionKey: overlayKey,
              child: KeyedSubtree(
                key: overlayKey,
                child: const SizedBox.expand(),
              ),
            ),
            onRevealedTap: _isAddTicketExpanded ? null : openAfter,
          ),
        ),
        const _DashedVerticalDivider(),
        Expanded(
          flex: 27,
          child: PressableScale(
            onTap: _isAddTicketExpanded ? null : openAfter,
            pressScale: 0.985,
            tapScale: 1.03,
            child: _hideWhileOverlayOpen(
              regionKey: posterOverlayKey,
              child: KeyedSubtree(
                key: posterOverlayKey,
                child: _buildAfterConcertPosterFace(
                  title: title,
                  info: info,
                  radiusOnRight: true,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// [_buildTicketAfterConcert]의 오른쪽(포스터) 영역 디자인. 정지 상태 UI와
  /// [ConcertAfterOverlay]의 collapsedTicket이 같은 모양을 보여줘야
  /// 자연스럽게 이어지므로 별도 위젯으로 뽑아 양쪽에서 재사용합니다.
  Widget _buildAfterConcertPosterFace({
    required String title,
    TicketInfo? info,
    bool radiusOnRight = false,
  }) {
    return _usePosterTicketDesign
        ? _PosterTicketFace(title: title, info: info, radiusOnRight: radiusOnRight)
        : Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: radiusOnRight
                  ? const BorderRadius.horizontal(right: Radius.circular(8))
                  : const BorderRadius.horizontal(left: Radius.circular(8)),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: context.sp(12),
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: context.sp(22),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
  }
}

/// "공연 후" 티켓의 본표와 입장 티켓 사이에 쓰는 점선 구분선(절취선 느낌).
class _DashedVerticalDivider extends StatelessWidget {
  const _DashedVerticalDivider();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 1,
      child: CustomPaint(
        size: const Size(double.infinity, double.infinity),
        painter: _DashedLinePainter(color: Colors.grey.shade400),
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  final Color color;

  const _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;

    const dashHeight = 5.0;
    const dashGap = 4.0;
    final x = size.width / 2;
    double y = 0;
    while (y < size.height) {
      final y2 = (y + dashHeight).clamp(0.0, size.height);
      canvas.drawLine(Offset(x, y), Offset(x, y2), paint);
      y += dashHeight + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 포스터가 녹아든 티켓 디자인 (_DiaryScreenState._usePosterTicketDesign으로
// 켜고 끕니다. false로 두면 아래 위젯들은 전혀 쓰이지 않고 기존 디자인 유지.)
// ─────────────────────────────────────────────────────────────────────────

/// 포스터가 없을 때 공연마다 서로 다른 무드의 배경을 주기 위한 그라데이션
/// 팔레트. 제목 문자열에서 결정적으로(앱을 껐다 켜도 동일하게) 골라, 같은
/// 공연은 항상 같은 색을 갖습니다.
const List<List<Color>> _posterFallbackPalettes = [
  [Color(0xFF241734), Color(0xFF7B4B94)], // 자주빛 밤
  [Color(0xFF0F2A43), Color(0xFF3E7CB1)], // 네이비
  [Color(0xFF3B2416), Color(0xFFB07D3D)], // 앰버 브라운
  [Color(0xFF12403C), Color(0xFF4C9A82)], // 딥 그린
  [Color(0xFF461426), Color(0xFFA34672)], // 버건디
];

List<Color> _posterFallbackGradient(String seedText) {
  var h = 0;
  for (final c in seedText.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _posterFallbackPalettes[h % _posterFallbackPalettes.length];
}

/// 티켓 왼쪽(본표) 영역: 공연 포스터를 꽉 채운 배경으로 깔고, 가독성을 위한
/// 어두운 스크림 위에 공연명/날짜·공연장/좌석·가격을 올립니다.
/// 포스터가 없거나 로드에 실패하면 공연별 그라데이션으로 폴백합니다.
///
/// [bigCenterText]를 주면(배송 전 티켓의 D-day) 공연명 대신 가운데 큰 텍스트
/// 레이아웃으로 바뀝니다.
class _PosterTicketFace extends StatelessWidget {
  const _PosterTicketFace({
    required this.title,
    this.info,
    this.bigCenterText,
    this.centerMessage,
    this.radiusOnRight = false,
  });

  final String title;
  final TicketInfo? info;
  final String? bigCenterText;

  /// [bigCenterText] 아래에 함께 보여줄 작은 안내 문구(예: 배송 전 티켓의
  /// "배송이 시작되었습니다!"). null이면 표시하지 않습니다.
  final String? centerMessage;

  /// 이 포스터 면이 카드의 오른쪽 끝에 놓일 때(예: 입장 티켓 라벨을 왼쪽으로
  /// 옮겨서 포스터가 오른쪽으로 밀린 경우) true로 줘서 바깥쪽 모서리
  /// (오른쪽)를 둥글게 한다. 기본값(false)은 기존처럼 왼쪽 모서리를
  /// 둥글게 한다.
  final bool radiusOnRight;

  static const List<Shadow> _textShadows = [
    Shadow(color: Colors.black45, blurRadius: 4),
  ];

  @override
  Widget build(BuildContext context) {
    final posterUrl = info?.posterImageUrl;

    return ClipRRect(
      borderRadius: radiusOnRight
          ? const BorderRadius.horizontal(right: Radius.circular(8))
          : const BorderRadius.horizontal(left: Radius.circular(8)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _posterFallbackGradient(title),
              ),
            ),
          ),
          // [백엔드 수정]
          // Image.network -> AppNetworkImage(디스크 캐싱+디코드 크기 축소).
          if (posterUrl != null && posterUrl.isNotEmpty)
            AppNetworkImage(
              posterUrl,
              fit: BoxFit.cover,
              // 그래도 실패하면 아무것도 그리지 않아 아래 그라데이션이 보임
              errorBuilder: (_) => const SizedBox.shrink(),
            ),
          // 텍스트 가독성을 위한 스크림(위/아래를 더 어둡게)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.32),
                  Colors.black.withValues(alpha: 0.10),
                  Colors.black.withValues(alpha: 0.45),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: bigCenterText != null
                ? _buildBigCenterLayout(context)
                : _buildConcertLayout(context),
          ),
        ],
      ),
    );
  }

  /// 배송 전 티켓: 작은 제목 + 가운데 큰 D-day.
  Widget _buildBigCenterLayout(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.sp(11),
            fontWeight: FontWeight.w800,
            color: Colors.white.withValues(alpha: 0.85),
            shadows: _textShadows,
          ),
        ),
        const Spacer(),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                bigCenterText!,
                style: TextStyle(
                  fontSize: context.sp(20),
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  shadows: _textShadows,
                ),
              ),
              if (centerMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  centerMessage!,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.sp(10),
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.92),
                    shadows: _textShadows,
                  ),
                ),
              ],
            ],
          ),
        ),
        const Spacer(),
      ],
    );
  }

  /// 공연 전/후 티켓: 큰 공연명 + 날짜·공연장 + 하단 좌석/가격.
  Widget _buildConcertLayout(BuildContext context) {
    final seat = info?.seat ?? '';
    final metaParts = <String>[
      if (info?.date != null) info!.formattedDate,
      if (info != null && info!.venueName.isNotEmpty) info!.venueName,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          // 날짜/공연장(metaParts)과 좌석/가격 줄까지 함께 있으면, 제목이
          // 2줄로 늘어날 때 카드의 좁은 높이 안에 다 들어가지 않아
          // RenderFlex 오버플로우가 났습니다(실제 서버 데이터처럼 제목이
          // 길 때 재현됨). 1줄로 제한하고 넘치면 말줄임표로 처리합니다.
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.sp(15),
            fontWeight: FontWeight.w900,
            color: Colors.white,
            height: 1.15,
            shadows: _textShadows,
          ),
        ),
        if (metaParts.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            metaParts.join(' | '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.sp(10.5),
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.85),
              shadows: _textShadows,
            ),
          ),
        ],
        const Spacer(),
        Row(
          children: [if (seat.isNotEmpty) _miniStat(context, '좌석', seat)],
        ),
      ],
    );
  }

  Widget _miniStat(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: context.sp(9),
            fontWeight: FontWeight.w700,
            color: Colors.white.withValues(alpha: 0.7),
            shadows: _textShadows,
          ),
        ),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: context.sp(11),
            fontWeight: FontWeight.w800,
            color: Colors.white,
            shadows: _textShadows,
          ),
        ),
      ],
    );
  }
}

/// 티켓 오른쪽(반권) 영역: 흰 배경에 라벨만 가운데 표시합니다.
class _TicketStub extends StatelessWidget {
  const _TicketStub({
    required this.label,
    this.labelColor,
    this.radiusOnLeft = false,
  });

  final String label;
  final Color? labelColor;

  /// 이 조각이 카드의 왼쪽 끝에 놓일 때(예: 입장 티켓 라벨을 왼쪽으로 옮긴
  /// 경우) true로 줘서 바깥쪽 모서리(왼쪽)를 둥글게 한다. 기본값(false)은
  /// 기존처럼 오른쪽 모서리를 둥글게 한다.
  final bool radiusOnLeft;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: radiusOnLeft
            ? const BorderRadius.horizontal(left: Radius.circular(8))
            : const BorderRadius.horizontal(right: Radius.circular(8)),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.sp(12),
              fontWeight: FontWeight.w800,
              color: labelColor ?? Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

// ===== [TEST-ONLY] 아래부터 파일 끝까지, "test 티켓 추가"의 숫자 날짜
// 입력에만 쓰이는 순수 헬퍼입니다. 테스트 탭을 통째로 지울 때 이 아래
// 내용도 함께 지우면 됩니다. =====

/// 지금까지 입력된 숫자만("2026826")을 연/월/일 부분 문자열로 나눕니다.
///
/// 월은 첫 글자가 '0'이나 '1'이고 다음 글자까지 합쳐 1~12가 되면 2자리를,
/// 그렇지 않으면(예: 첫 글자가 2~9거나 "13"~"19"처럼 무효한 조합) 1자리만
/// 가져갑니다 — 그래야 "8"만 입력해도 곧바로 8월로 확정되고, 남은 숫자가
/// 바로 "일"로 넘어갑니다("2026826" -> 년=2026, 월=8, 일=26). 일은 남은
/// 숫자를 그대로(최대 2자리) 가져갑니다.
({String year, String month, String day}) _debugYmdSegments(String digits) {
  final capped = digits.length > 8 ? digits.substring(0, 8) : digits;
  if (capped.length <= 4) return (year: capped, month: '', day: '');
  final year = capped.substring(0, 4);
  final rest = capped.substring(4);
  final String month;
  if (rest.length == 1) {
    month = rest;
  } else if (rest[0] == '0' || rest[0] == '1') {
    final firstTwo = int.parse(rest.substring(0, 2));
    month = (firstTwo >= 1 && firstTwo <= 12)
        ? rest.substring(0, 2)
        : rest.substring(0, 1);
  } else {
    month = rest.substring(0, 1);
  }
  final dayFull = rest.substring(month.length);
  final day = dayFull.length > 2 ? dayFull.substring(0, 2) : dayFull;
  return (year: year, month: month, day: day);
}

/// 입력 중인 숫자를 "2026년 8월 26일" 형태로 실시간 표시합니다. 연 4자리가
/// 다 채워지기 전에는 숫자를 그대로 보여줍니다.
String _formatDebugYmdDigits(String digits) {
  final seg = _debugYmdSegments(digits);
  if (seg.year.length < 4) return seg.year;
  final buffer = StringBuffer('${seg.year}년');
  if (seg.month.isNotEmpty) buffer.write(' ${int.parse(seg.month)}월');
  if (seg.day.isNotEmpty) buffer.write(' ${int.parse(seg.day)}일');
  return buffer.toString();
}

/// 화면에 표시된 문자열(또는 원시 숫자)에서 연/월/일을 모두 뽑아낼 수
/// 있으면 [DateTime]으로 변환합니다. 아직 다 안 채워졌거나 월/일이
/// 달력상 불가능한 값이면(예: 13월) null입니다.
DateTime? _parseDebugYmdDigits(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  final seg = _debugYmdSegments(digits);
  if (seg.year.length < 4 || seg.month.isEmpty || seg.day.isEmpty) {
    return null;
  }
  final month = int.parse(seg.month);
  final day = int.parse(seg.day);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime(int.parse(seg.year), month, day);
}

/// [TEST-ONLY] 숫자만 받아 [_formatDebugYmdDigits]로 실시간 재포맷하는
/// [TextField] 전용 포매터.
class _DebugYmdInputFormatter extends TextInputFormatter {
  const _DebugYmdInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final oldDigits = oldValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final String digits;
    if (newValue.text.length < oldValue.text.length) {
      // 삭제(백스페이스): 화면엔 "년/월/일" 같은 숫자가 아닌 글자도 섞여
      // 있어서 마지막 한 글자를 그대로 지우면 그 글자만 사라지고 숫자는
      // 그대로일 수 있습니다. 항상 "숫자" 기준 마지막 한 자리를 지운
      // 것으로 취급합니다.
      digits = oldDigits.isEmpty
          ? ''
          : oldDigits.substring(0, oldDigits.length - 1);
    } else {
      digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    }
    final capped = digits.length > 8 ? digits.substring(0, 8) : digits;
    final formatted = _formatDebugYmdDigits(capped);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
