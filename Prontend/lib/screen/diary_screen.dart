import 'dart:async';

import 'package:flutter/material.dart';
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
  const DiaryScreen({super.key});

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
  /// 단, "배송 전" 상태는 실제 플로우로는 아직 도달할 방법이 없어 화면을
  /// 확인할 수 있도록 예시 티켓을 하나 미리 넣어둡니다.
  ///
  /// "공연 전 티켓 예시"는 일부러 "공연 전" 상태 + 이미 지난 공연 날짜(=공연
  /// 시간이 지난 뒤의 첫 실행)로 만들어뒀습니다. 이렇게 공연 시간이 지난
  /// "공연 전" 티켓은 [_isDueForPromotion]이 true를 반환해 반짝이는 효과
  /// ([SparkleHighlight])가 표시되고, 사용자가 이 티켓을 누르면 그때
  /// [_runTicketPromotionAnimation]이 실행되어 "공연 후"로 전환됩니다.
  ///
  /// `static`인 이유: 다른 탭으로 이동했다가 "다이어리" 탭으로 돌아오면
  /// [DiaryTab] 라우팅 구조상(diary_tabs.dart의 `pushNamedAndRemoveUntil`)
  /// 매번 새 [DiaryScreen] State가 생성됩니다. 이 필드가 인스턴스 필드였다면
  /// 화면을 나갔다 돌아올 때마다 초기화돼서, 눌러서 "공연 후"로 전환해둔
  /// 티켓이 다시 "공연 전"으로 리셋되는 문제가 있었습니다. `static`으로 두면
  /// 앱이 실행되는 동안 State가 몇 번을 새로 생기든 같은 리스트를 계속
  /// 공유하므로 전환 결과가 유지됩니다.
  static final List<TicketData> _tickets = [
    TicketData(title: '배송 전 티켓 예시', status: TicketStatus.beforeDelivery),
    TicketData(
      title: '공연 전 티켓 예시',
      status: TicketStatus.beforeConcert,
      info: TicketInfo(
        date: DateTime.now().subtract(const Duration(minutes: 1)),
      ),
    ),
  ];

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
  /// 것으로 다시 불러오기 위해 씁니다([_onAuthChanged] 참고).
  static String? _loadedForUserId;

  @override
  void initState() {
    super.initState();
    // "공연 전" 페이지의 예상 셋 리스트 블러 여부에 쓰이는 설정값을 미리 불러옵니다.
    AppSettingsStore.instance.load();
    AuthService.instance.addListener(_onAuthChanged);
    TicketRefreshBus.tick.addListener(_onTicketsChangedElsewhere);
    unawaited(_loadTicketsFromBackend());
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    TicketRefreshBus.tick.removeListener(_onTicketsChangedElsewhere);
    _flipAnimating.dispose();
    super.dispose();
  }

  /// 게스트→카카오 마이그레이션이 로컬 티켓을 서버로 다 옮긴 뒤 보내는
  /// 알림. 유저 id는 이미 마이그레이션 시작 시점에 바뀌어 [_onAuthChanged]가
  /// 한 번 지나갔으므로, 여기서는 그 가드와 무관하게 강제로 다시 불러옵니다.
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

  /// 로그인 상태가 바뀔 때마다(로그인/로그아웃/게스트↔카카오 전환) 호출됩니다.
  /// 로그인된 유저가 마지막으로 티켓을 불러왔던 유저와 다르면, 이전 유저의
  /// 실제 티켓(백엔드든 게스트 로컬 저장이든, `info.ticketId`가 있는 것)을
  /// 화면에서 지우고 새 유저 것으로 다시 불러옵니다. 로컬 전용 예시 티켓은
  /// 계정과 무관하므로 그대로 둡니다.
  void _onAuthChanged() {
    final currentUserId = AuthService.instance.userId;
    if (currentUserId == _loadedForUserId) return;

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

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    try {
      final extracted = scanResult.extracted;
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
        price: extracted.price,
        seatType: extracted.seat,
      );

      if (!mounted) return;
      Navigator.pop(context); // 로딩 다이얼로그 닫기

      setState(() {
        _tickets.insert(
          0,
          TicketData.fromBackend(ticket, scanExtracted: extracted),
        );
      });
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
                style: TextStyle(fontSize: context.sp(15), fontWeight: FontWeight.w800),
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

  /// "YYYY-MM-DD" 문자열(백엔드 `shipping_date` 등)을 [DateTime]으로 변환합니다.
  /// 형식이 아니거나 없으면 null.
  DateTime? _parseYmd(String? yyyyMmDd) {
    if (yyyyMmDd == null) return null;
    return DateTime.tryParse(yyyyMmDd);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
      ],
    );
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
    // _buildTicketPocket이 실제로는 이 너비의 1.1배로 그리므로 그만큼 반영합니다.
    final double itemWidth = constraints.maxWidth - 50;
    final double itemHeight = (itemWidth * 1.1) / _ticketAspectRatio;

    // 첫 페이지: 버튼 1개 + 티켓 3개(총 4개, 모두 같은 높이) + 항목 사이 간격 3곳
    // 이후 페이지: 티켓 4개(모두 같은 높이) + 항목 사이 간격 3곳
    final double targetTotalHeight = isFirstPage
        ? (itemHeight * (_firstPageTicketCapacity + 1)) +
              (_ticketSpacing * _firstPageTicketCapacity)
        : (itemHeight * _otherPageTicketCapacity) +
              (_ticketSpacing * (_otherPageTicketCapacity - 1));
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
              ), // 계산된 고정 상단 여백
              if (isFirstPage) ...[
                _buildAddTicketArea(context),
                const SizedBox(height: _ticketSpacing), // 추가 버튼과 리스트 사이 간격(티켓 간격과 동일)
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
                            child: _buildTicketByStatus(ticket),
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

  Widget _buildTicketByStatus(TicketData ticket) {
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
              : () {
                  final startRect = _globalRectOf(ticket.overlayKey);
                  if (startRect == null) return;

                  ConcertBeforeOverlay.show(
                    context,
                    startRect: startRect,
                    collapsedTicket: _buildTicketPocket(
                      child: _buildTicketBeforeConcert(
                        title: ticket.title,
                        info: ticket.info,
                      ),
                    ),
                    concertTitle: ticket.title,
                    ticketInfo: ticket.info,
                  );
                },
          child: KeyedSubtree(
            key: ticket.overlayKey,
            child: _buildTicketPocket(
              child: _buildTicketBeforeConcert(
                title: ticket.title,
                info: ticket.info,
              ),
            ),
          ),
        );
        return isDue
            ? SparkleHighlight(child: ticketWidget)
            : ticketWidget;
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
    return _buildTicketPocket(
      child: Container(
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
    );
  }

  Widget _buildTicketPocket({required Widget child}) {
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
            width: constraints.maxWidth * 1.1,
            child: AspectRatio(
              aspectRatio: _ticketAspectRatio,
              child: Container(
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
              ),
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

  Widget _buildTicketBeforeDelivery({required String title, TicketInfo? info}) {
    final dDayLabel = _deliveryDDayLabel(info?.deliveryDate);
    final isRegisterReady = _isDeliveryDue(info?.deliveryDate);
    final vendorLabel = isRegisterReady
        ? '등록'
        : ((info?.vendorName?.isNotEmpty ?? false) ? info!.vendorName! : '예매처');

    if (_usePosterTicketDesign) {
      return Row(
        children: [
          Expanded(
            flex: 27, // 왼쪽 67.5%(=기존 75%에서, 왼쪽 폭의 10%만큼 절취선을 왼쪽으로 옮김)
            child: _PosterTicketFace(
              title: title,
              info: info,
              bigCenterText: dDayLabel,
            ),
          ),
          Container(width: 1, color: Colors.grey.shade400),
          Expanded(
            flex: 13, // 오른쪽(뜯는 부분) 32.5%로 확대(기존 25% + 절취선 이동분 7.5%)
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: isRegisterReady && !_isAddTicketExpanded
                  ? () => _startCameraScan()
                  : null,
              child: _TicketStub(
                label: vendorLabel,
                labelColor: isRegisterReady ? const Color(0xFF16A34A) : null,
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          flex: 27, // 왼쪽 67.5%(=기존 75%에서, 왼쪽 폭의 10%만큼 절취선을 왼쪽으로 옮김)
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
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
                const Spacer(),
              ],
            ),
          ),
        ),
        Container(width: 1, color: Colors.grey.shade400),
        Expanded(
          flex: 13, // 오른쪽(뜯는 부분) 32.5%로 확대(기존 25% + 절취선 이동분 7.5%)
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: isRegisterReady && !_isAddTicketExpanded
                ? () => _startCameraScan()
                : null,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.horizontal(
                  right: Radius.circular(8),
                ),
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
        ),
      ],
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
            width: 36,
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
    if (_usePosterTicketDesign) {
      return Row(
        children: [
          Expanded(
            flex: 27, // 왼쪽 67.5%(=기존 75%에서, 왼쪽 폭의 10%만큼 절취선을 왼쪽으로 옮김)
            child: _PosterTicketFace(title: title, info: info),
          ),
          Container(width: 1, color: Colors.grey.shade400),
          const Expanded(
            flex: 13, // 오른쪽(뜯는 부분) 32.5%로 확대(기존 25% + 절취선 이동분 7.5%)
            child: _TicketStub(label: '입장 티켓'),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          flex: 27, // 왼쪽 67.5%(=기존 75%에서, 왼쪽 폭의 10%만큼 절취선을 왼쪽으로 옮김)
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
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
        Container(width: 1, color: Colors.grey.shade400),
        Expanded(
          flex: 13, // 오른쪽(뜯는 부분) 32.5%로 확대(기존 25% + 절취선 이동분 7.5%)
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.horizontal(right: Radius.circular(8)),
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
    return Row(
      children: [
        Expanded(
          flex: 27, // 왼쪽 67.5%(=기존 75%에서, 왼쪽 폭의 10%만큼 절취선을 왼쪽으로 옮김)
          child: PressableScale(
            onTap: _isAddTicketExpanded
                ? null
                : () {
                    // "공연 전" 티켓과 동일한 로직: 일반 push 대신, 눌린
                    // 티켓 위치(Rect)에서 자연스럽게 확장되는 오버레이로
                    // 상세를 보여줍니다.
                    final startRect = _globalRectOf(posterOverlayKey);
                    if (startRect == null) return;

                    ConcertAfterOverlay.show(
                      context,
                      startRect: startRect,
                      collapsedTicket: _buildAfterConcertPosterFace(
                        title: title,
                        info: info,
                      ),
                      concertTitle: title,
                      ticketInfo: info,
                      onTicketInfoChanged: onInfoChanged,
                    );
                  },
            pressScale: 0.985,
            tapScale: 1.03,
            child: KeyedSubtree(
              key: posterOverlayKey,
              child: _buildAfterConcertPosterFace(title: title, info: info),
            ),
          ),
        ),
        const _DashedVerticalDivider(),
        Expanded(
          flex: 13, // 오른쪽(뜯는 부분) 32.5%로 확대(기존 25% + 절취선 이동분 7.5%)
          child: EntryTicketTearPiece(
            enabled: !_isAddTicketExpanded,
            vibrate: vibrate,
            initiallyRevealed: initiallyRevealed,
            onTorn: onTorn,
            // 뜯기 전: 다른 티켓 오른쪽 칸과 동일한 디자인 + "관람 완료" 라벨
            front: _usePosterTicketDesign
                ? const _TicketStub(label: '관람 완료')
                : DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.horizontal(
                        right: Radius.circular(8),
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
            // 뜯긴 뒤: 지금의 "공연전" 디자인이 남아서 눌러볼 수 있게 됨
            revealed: KeyedSubtree(
              key: overlayKey,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.horizontal(
                    right: Radius.circular(8),
                  ),
                ),
                child: _concertBeforeShortcutWidget(dark: true),
              ),
            ),
            onRevealedTap: () {
              final startRect = _globalRectOf(overlayKey);
              if (startRect == null) return;
              ConcertBeforeOverlay.show(
                context,
                startRect: startRect,
                collapsedTicket: _concertBeforeShortcutWidget(dark: true),
                concertTitle: title,
                ticketInfo: info,
              );
            },
          ),
        ),
      ],
    );
  }

  /// [_buildTicketAfterConcert]의 왼쪽(포스터) 영역 디자인. 정지 상태 UI와
  /// [ConcertAfterOverlay]의 collapsedTicket이 같은 모양을 보여줘야
  /// 자연스럽게 이어지므로 별도 위젯으로 뽑아 양쪽에서 재사용합니다.
  Widget _buildAfterConcertPosterFace({
    required String title,
    TicketInfo? info,
  }) {
    return _usePosterTicketDesign
        ? _PosterTicketFace(title: title, info: info)
        : Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.horizontal(
                left: Radius.circular(8),
              ),
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

  Widget _concertBeforeShortcutWidget({bool dark = false}) {
    return Container(
      color: dark ? const Color(0xFFE6E6E6) : Colors.white,
      child: Center(
        child: Text(
          "공연전",
          style: TextStyle(
            fontSize: context.sp(12),
            fontWeight: FontWeight.w800,
            color: dark ? Colors.black54 : Colors.black54,
          ),
        ),
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
  });

  final String title;
  final TicketInfo? info;
  final String? bigCenterText;

  static const List<Shadow> _textShadows = [
    Shadow(color: Colors.black45, blurRadius: 4),
  ];

  @override
  Widget build(BuildContext context) {
    final posterUrl = info?.posterImageUrl;

    return ClipRRect(
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(8)),
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
          if (posterUrl != null && posterUrl.isNotEmpty)
            Image.network(
              posterUrl,
              fit: BoxFit.cover,
              // KOPIS처럼 CORS 헤더가 없는 이미지 서버는 웹에서 일반 로드가
              // 실패하므로, 실패 시 <img> 태그로 대신 렌더링합니다(웹 전용).
              webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
              // 그래도 실패하면 아무것도 그리지 않아 아래 그라데이션이 보임
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
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
          child: Text(
            bigCenterText!,
            style: TextStyle(
              fontSize: context.sp(20),
              fontWeight: FontWeight.w900,
              color: Colors.white,
              shadows: _textShadows,
            ),
          ),
        ),
        const Spacer(),
      ],
    );
  }

  /// 공연 전/후 티켓: 큰 공연명 + 날짜·공연장 + 하단 좌석/가격.
  Widget _buildConcertLayout(BuildContext context) {
    final seat = info?.seat ?? '';
    final price = info?.price ?? '';
    final metaParts = <String>[
      if (info?.date != null) info!.formattedDate,
      if (info != null && info!.venueName.isNotEmpty) info!.venueName,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
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
          children: [
            if (seat.isNotEmpty) _miniStat(context, '좌석', seat),
            if (seat.isNotEmpty && price.isNotEmpty) const SizedBox(width: 14),
            if (price.isNotEmpty) _miniStat(context, '가격', price),
          ],
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
  const _TicketStub({required this.label, this.labelColor});

  final String label;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.horizontal(right: Radius.circular(8)),
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
