import 'dart:async';

import 'package:flutter/material.dart';

import 'concert_after_screen.dart';
import 'concert_before_overlay.dart';
import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/services/app_settings_store.dart';
import 'package:ticketdiary/services/concert_lookup_service.dart';
import 'package:ticketdiary/services/ticket_ocr_service.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';
import 'package:ticketdiary/widgets/add_ticket_option.dart';
import 'package:ticketdiary/widgets/entry_ticket_tear_piece.dart';
import 'package:ticketdiary/widgets/pressable_scale.dart';
import 'package:ticketdiary/widgets/sparkle_highlight.dart';
import 'package:ticketdiary/widgets/ticket_flip_card.dart';
import 'package:ticketdiary/widgets/diary_page_flipper.dart';
import 'package:ticketdiary/widgets/ticket_scan_camera_screen.dart';

class TicketData {
  final String title;
  final TicketStatus status;

  /// 스캔으로 추출된 상세 정보(공연장/날짜/가격/좌석 등). 없을 수도 있습니다.
  final TicketInfo? info;

  /// 오버레이 확장 애니메이션의 시작 위치(Rect)를 구하기 위한 티켓별 고유 key.
  /// 여러 티켓이 동시에 화면(앞/뒷 페이지)에 존재할 수 있으므로 티켓마다 별도로 가져야 합니다.
  final GlobalKey overlayKey;

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
       id = id ?? 'ticket_${_nextId++}';
}

enum TicketStatus { beforeDelivery, beforeConcert, afterConcert, error }

class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  static const Color _paperColor = Color(0xFFF4F1E1);

  bool _isAddTicketExpanded = false;

  /// "공연 전 -> 공연 후" 전환 애니메이션이 재생되는 동안, 사용자가 다른 조작을
  /// 하다가 애니메이션을 놓치거나 겹쳐 실행되지 않도록 잠깐 막아둡니다.
  bool _interactionLocked = false;

  /// 다중 페이지 상태
  int _currentPageIndex = 0;

  /// 첫 페이지는 티켓추가 버튼 + 티켓 3개, 이후 페이지부터는 티켓 4개씩 채웁니다.
  static const int _firstPageTicketCapacity = 3;
  static const int _otherPageTicketCapacity = 4;

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

  final TicketOcrService _ocrService = const MockTicketOcrService();

  /// 백엔드에 등록된 공연인지 확인하는 서비스(백엔드 연동 전까지는 mock 사용)
  final ConcertLookupService _concertLookupService =
      const MockConcertLookupService();

  /// "공연 전 -> 공연 후" 전환 페이드 지속 시간. 두 디자인이 겹쳐 보이는 구간이
  /// 보이도록 하되, 너무 늘어지지 않게 6초의 50% 속도(=3초)로 잡습니다.
  static const Duration _promotionFadeDuration = Duration(seconds: 3);

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

  @override
  void initState() {
    super.initState();
    // "공연 전" 페이지의 예상 셋 리스트 블러 여부에 쓰이는 설정값을 미리 불러옵니다.
    AppSettingsStore.instance.load();
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
  Future<void> _startCameraScan() async {
    setState(() => _isAddTicketExpanded = false);

    final TicketInfo? info = await Navigator.of(context).push<TicketInfo>(
      MaterialPageRoute(
        builder: (_) => TicketScanCameraScreen(ocrService: _ocrService),
        fullscreenDialog: true,
      ),
    );

    if (info == null || !mounted) return;
    await _addTicketIfConcertExists(info);
  }

  /// 갤러리 기능은 아직 준비 중입니다.
  void _pickFromGalleryAndAnalyze() {
    setState(() => _isAddTicketExpanded = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('곧 기능이 추가됩니다!')));
  }

  /// 스캔된 [TicketInfo]의 공연이 백엔드에 등록되어 있는지 확인한 뒤,
  /// 사용자가 수정할 수 없도록 바로 "공연 전" 상태의 티켓으로 다이어리에 추가합니다.
  Future<void> _addTicketIfConcertExists(TicketInfo info) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    final exists = await _concertLookupService.exists(info.concertName);

    if (!mounted) return;
    Navigator.pop(context);

    if (!exists) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('오래되었거나 일치하는 공연이 없습니다!')));
      return;
    }

    setState(() {
      _tickets.insert(
        0,
        TicketData(
          title: info.concertName,
          status: TicketStatus.beforeConcert,
          info: info,
        ),
      );
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('다이어리에 티켓이 추가되었습니다.')));
  }

  @override
  Widget build(BuildContext context) {
    final nextPageIndex = (_currentPageIndex + 1) % _totalPages;
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
                  vibrate: !_transitionSpotlightIds.contains(ticket.id),
                  initiallyRevealed: ticket.tornRevealed,
                ),
              )
            : _buildTicketPocket(
                child: _buildTicketBeforeConcert(title: ticket.title),
              ),
      ),
    );
  }

  Widget _buildDiaryPageFrameWithFlip(int pageIndex, int nextPageIndex) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DiaryPageFrame(
          isTabRoot: _currentPageIndex == pageIndex && pageIndex == 0,
          sideTabs: buildDiarySideTabs(context, active: DiaryTab.diary),
          animateMainPage: true,
          overlayMainPage: DiaryPageFlipper(
            key: ValueKey('flipper_$_currentPageIndex'),
            frontPage: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: _paperColor,
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(15),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(5, 5),
                  ),
                ],
              ),
              child: _buildPageContent(pageIndex, constraints),
            ),
            backPage: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: _paperColor,
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(15),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(5, 5),
                  ),
                ],
              ),
              child: _buildPageContent(nextPageIndex, constraints),
            ),
            onFlipForward: _currentPageIndex < _totalPages - 1
                ? () {
                    final now = DateTime.now();
                    if (now.difference(_lastFlipTime) < _flipCooldown) return;
                    _lastFlipTime = now;
                    setState(() => _currentPageIndex++);
                  }
                : null,
            flipUpward: false,
          ),
          child: const SizedBox.shrink(),
        );
      },
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
    return Container(
      height: 100,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.60),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.grey.shade400, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(2, 4),
          ),
        ],
      ),
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

    // 첫 페이지: 100(추가버튼) + 30(간격) + (120 * 3)(티켓3개) + (25 * 2)(티켓간격) = 540
    // 이후 페이지: (120 * 4)(티켓4개) + (25 * 3)(티켓간격) = 555
    final double targetTotalHeight = isFirstPage
        ? 100 +
              30 +
              (120 * _firstPageTicketCapacity) +
              (25 * (_firstPageTicketCapacity - 1))
        : (120 * _otherPageTicketCapacity) +
              (25 * (_otherPageTicketCapacity - 1));
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
                const SizedBox(height: 30), // 추가 버튼과 리스트 사이 간격 고정
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
                      const SizedBox(height: 25),
                  itemBuilder: (context, index) {
                    final ticket = pageTickets[index];
                    // 공연 시간이 지나 "공연 전" -> "공연 후"로 자동 전환될 때,
                    // 같은 자리에서 자연스럽게 페이드 인아웃되도록 상태를 key로 씁니다.
                    // 바깥의 KeyedSubtree는 전환 강조 오버레이가 이 티켓의 화면
                    // 위치(Rect)를 찾을 수 있도록 붙여둔 것입니다.
                    return KeyedSubtree(
                      key: _highlightKeyFor(ticket.id),
                      child: AnimatedSwitcher(
                        duration: _promotionFadeDuration,
                        child: KeyedSubtree(
                          key: ValueKey(ticket.status),
                          child: _buildTicketByStatus(ticket),
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
                      child: _buildTicketBeforeConcert(title: ticket.title),
                    ),
                    concertTitle: ticket.title,
                    ticketInfo: ticket.info,
                  );
                },
          child: KeyedSubtree(
            key: ticket.overlayKey,
            child: _buildTicketPocket(
              child: _buildTicketBeforeConcert(title: ticket.title),
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
            // 방금 "공연 전 -> 공연 후"로 전환된 티켓은, 전환 애니메이션이
            // 완전히 끝날 때까지(_transitionSpotlightIds에서 빠질 때까지)
            // 진동을 멈춰뒀다가 그 이후에 시작합니다.
            vibrate: !_transitionSpotlightIds.contains(ticket.id),
            // 이전에 이미 뜯어둔 티켓이면(다이어리 화면을 나갔다 왔어도) 다시
            // 뜯긴 상태로 보여주고, 처음 뜯는 순간에는 티켓 데이터에 기록해서
            // 이후에도 계속 뜯긴 채로 유지되게 합니다.
            initiallyRevealed: ticket.tornRevealed,
            onTorn: () => setState(() => ticket.tornRevealed = true),
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
    return Container(
      height: 100,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: Colors.grey.shade400,
          width: 2,
          style: BorderStyle.solid,
        ),
      ),
      child: const Center(
        child: Text(
          "티켓  추가",
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
            letterSpacing: 4.0,
          ),
        ),
      ),
    );
  }

  Widget _buildTicketPocket({required Widget child}) {
    return Container(
      height: 120,
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

    return Row(
      children: [
        Expanded(
          flex: 3,
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
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const Spacer(),
                Center(
                  child: Text(
                    dDayLabel,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 18,
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
          flex: 1,
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
                    fontSize: 12,
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
              style: const TextStyle(
                fontSize: 11,
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
              style: const TextStyle(
                fontSize: 12,
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
          const Text(
            '공연 정보',
            style: TextStyle(
              fontSize: 12,
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

  Widget _buildTicketBeforeConcert({required String title}) {
    return Row(
      children: [
        Expanded(
          flex: 3,
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
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 22,
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
          flex: 1,
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
                  fontSize: 12,
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
    bool vibrate = true,
    bool initiallyRevealed = false,
    VoidCallback? onTorn,
  }) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: PressableScale(
            onTap: _isAddTicketExpanded
                ? null
                : () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ConcertAfterScreen(concertTitle: title),
                      ),
                    );
                  },
            pressScale: 0.985,
            tapScale: 1.03,
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
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const _DashedVerticalDivider(),
        Expanded(
          flex: 1,
          child: EntryTicketTearPiece(
            enabled: !_isAddTicketExpanded,
            vibrate: vibrate,
            initiallyRevealed: initiallyRevealed,
            onTorn: onTorn,
            // 뜯기 전: 다른 티켓 오른쪽 칸과 동일한 디자인 + "관람 완료" 라벨
            front: DecoratedBox(
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
                    fontSize: 12,
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

  Widget _concertBeforeShortcutWidget({bool dark = false}) {
    return Container(
      color: dark ? const Color(0xFFE6E6E6) : Colors.white,
      child: Center(
        child: Text(
          "공연전",
          style: TextStyle(
            fontSize: 12,
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
