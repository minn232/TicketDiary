import 'package:flutter/material.dart';

import '../models/notification_display.dart';
import '../models/notification_model.dart';
import '../services/api_client.dart';
import '../services/notifications_service.dart';
import '../widgets/app_network_image.dart';
import '../widgets/diary_route.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/responsive_text.dart';
import '../widgets/sheet_grab_handle.dart';
import '../widgets/tab_nav_coordinator.dart';
import '../widgets/paper_style.dart';

// [백엔드 수정]
// 인앱 알림함 (GET/PATCH/DELETE /notifications)
// 전체 화면 전환 대신 슬라이드업 오버레이+다이어리 스타일로 재구성.
/// 인앱 알림함. 설정 화면 등에서 진입.
class NotificationsScreen extends StatefulWidget {
  /// 탭한 순간 설정 화면에서 쓰이던 [DiaryFrameScale] 배율.
  final double frameScale;

  /// 테스트에서 실제 네트워크 없이 주입할 수 있도록 둔 서비스(기본값은
  /// 실제 [NotificationsService]).
  final NotificationsService? service;

  const NotificationsScreen({
    super.key,
    required this.frameScale,
    this.service,
  });

  /// 지금 화면 위에 알림함 패널을 슬라이드업으로 띄우는 헬퍼.
  static Future<void> show(
    BuildContext context, {
    required double frameScale,
    NotificationsService? service,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'notifications_overlay',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (context, animation, secondaryAnimation) {
        return NotificationsScreen(frameScale: frameScale, service: service);
      },
    );
  }

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with TickerProviderStateMixin {
  late final NotificationsService _service =
      widget.service ?? NotificationsService();

  List<NotificationModel>? _items;
  String? _errorMessage;

  // 매번 새로 fetch하는 FutureBuilder 대신 목록을 로컬에서 직접 들고
  // 낙관적으로 갱신 - 안 그러면 Dismissible 스와이프 삭제 직후 "still
  // part of the tree" 예외가 남.
  final Set<String> _locallyRead = {};

  late final AnimationController _controller;
  late final Animation<double> _t;

  // [백엔드 수정] 창이 다 올라오고 목록도 받은 뒤 카드들이 차례로 떠오르는 연출(한 번만).
  late final AnimationController _listIn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );

  bool _isClosing = false;

  /// 손잡이를 드래그해서 직접 닫는 동안엔 컨트롤러 값을 애니메이션이 아니라
  /// 손가락 움직임에 맞춰 직접 정함.
  bool _dragging = false;

  static const Color _paperColor = Color(0xFFF4F1E1);
  static const Color _cardColor = PaperColors.card;
  static const Color _unreadAccent = PaperColors.stamp;
  static const Color _deleteAccent = PaperColors.stamp;

  @override
  void initState() {
    super.initState();
    _load();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _t = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.forward().whenComplete(_maybeStartListIn);
  }

  @override
  void dispose() {
    _controller.dispose();
    _listIn.dispose();
    super.dispose();
  }

  void _maybeStartListIn() {
    if (!mounted || _items == null || !_controller.isCompleted) return;
    if (_listIn.isDismissed) _listIn.forward();
  }

  Future<void> _load() async {
    setState(() => _errorMessage = null);
    try {
      final items = await _service.list();
      if (!mounted) return;
      setState(() => _items = items);
      _maybeStartListIn();
    } catch (e) {
      if (!mounted) return;
      final message = e is ApiException ? '오류 (${e.statusCode})' : '오류 (연결 실패)';
      setState(() => _errorMessage = message);
    }
  }

  bool _isRead(NotificationModel item) =>
      item.isRead || _locallyRead.contains(item.id);

  Future<void> _markRead(NotificationModel item) async {
    if (_isRead(item)) return;
    setState(() => _locallyRead.add(item.id));
    try {
      await _service.markRead(item.id);
    } catch (_) {
      // 실패해도 조용히 무시 - 다음에 알림함을 다시 열면 여전히
      // 안읽음으로 보일 뿐, 지금 열려있는 동안은 읽은 상태로 둠.
    }
  }

  Future<void> _delete(NotificationModel item) async {
    final items = _items;
    if (items == null) return;
    final index = items.indexOf(item);
    // 스와이프로 이미 지워진 뒤라, API 실패해도 되돌리지 않고 안내만 함
    // (되돌리면 방금 지운 카드가 다시 나타나 어색함).
    setState(() => items.removeAt(index));
    try {
      await _service.delete(item.id);
    } catch (e) {
      if (!mounted) return;
      final message = e is ApiException ? e.message : '잠시 후 다시 시도해주세요.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('삭제하지 못했어요: $message')));
    }
  }

  Future<void> _close() async {
    if (_isClosing) return;
    _isClosing = true;
    try {
      await _controller.reverse();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  void _onHandleDragStart(DragStartDetails details) {
    _dragging = true;
    _controller.stop();
  }

  void _onHandleDragUpdate(DragUpdateDetails details, double panelHeight) {
    if (!_dragging || panelHeight <= 0) return;
    final delta = details.primaryDelta ?? 0;
    _controller.value = (_controller.value - delta / panelHeight).clamp(
      0.0,
      1.0,
    );
  }

  void _onHandleDragEnd(DragEndDetails details) {
    _dragging = false;
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 300 || _controller.value < 0.6) {
      _close();
    } else {
      _controller.forward();
    }
  }

  // [백엔드 수정] 누르면 읽음 처리 후 그 알림의 화면으로 - 공연 전날/당일/배송은 다이어리의
  // 그 티켓, 티켓팅/새 공연은 소식 탭의 그 공연 카드(결산 캘린더와 같은 이동+자동 열기 경로).
  Future<void> _openItem(NotificationModel item) async {
    _markRead(item);
    final kind = NotificationKind.of(item.type);
    final ticketId = item.ticketId;
    final concertId = item.concertId;
    final DiaryTab target;
    if (kind.opensTicket && ticketId != null) {
      TabNavCoordinator.instance.pendingDiaryTicketId = ticketId;
      target = DiaryTab.diary;
    } else if (!kind.opensTicket && concertId != null) {
      TabNavCoordinator.instance
        ..pendingNewsConcertId = concertId
        ..pendingNewsConcertName = item.title;
      target = DiaryTab.news;
    } else {
      return;
    }
    await _close();
    TabNavCoordinator.instance.requestTab(target);
  }

  // [백엔드 수정] 모두 읽음 - 화면은 바로 바꾸고, 실패하면 안내만(다음에 열면 안읽음으로 보일 뿐).
  Future<void> _markAllRead() async {
    final items = _items;
    if (items == null) return;
    setState(() => _locallyRead.addAll(items.map((e) => e.id)));
    try {
      await _service.markAllRead();
    } catch (e) {
      if (!mounted) return;
      final message = e is ApiException ? e.message : '잠시 후 다시 시도해주세요.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('모두 읽음 처리하지 못했어요: $message')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DiaryFrameScale(
      scale: widget.frameScale,
      marginEachSide: 0,
      // [백엔드 수정]
      // 뒤로가기 키가 기본 팝 전환(페이드)으로 바로 닫혀서 X버튼/드래그로
      // 닫을 때(슬라이드다운)와 안 맞던 것 - PopScope로 가로채 _close()를
      // 타도록 통일.
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          _close();
        },
        child: AnimatedBuilder(
          animation: _t,
          builder: (context, child) {
            final t = _t.value;
            return Stack(
              children: [
                // 패널 위쪽에 드러나는 배경을 어둡게 - 탭하면 닫힘.
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _close,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.45 * t),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 0.9,
                    child: FractionalTranslation(
                      translation: Offset(0, 1 - t),
                      child: child,
                    ),
                  ),
                ),
              ],
            );
          },
          child: _NotificationsPanel(
            onHandleDragStart: _onHandleDragStart,
            onHandleDragUpdate: _onHandleDragUpdate,
            onHandleDragEnd: _onHandleDragEnd,
            onClose: _close,
            onRefresh: _load,
            entrance: _listIn,
            items: _items,
            errorMessage: _errorMessage,
            isRead: _isRead,
            onTapItem: _openItem,
            onMarkAllRead: _markAllRead,
            onDismissItem: _delete,
            now: DateTime.now(),
            paperColor: _paperColor,
            cardColor: _cardColor,
            unreadAccent: _unreadAccent,
            deleteAccent: _deleteAccent,
          ),
        ),
      ),
    );
  }
}

/// 알림함 패널 내용(손잡이+헤더+목록). 애니메이션 중엔 [AnimatedBuilder.child]
/// 로 재사용되도록 별도 위젯으로 뺐음.
class _NotificationsPanel extends StatelessWidget {
  final void Function(DragStartDetails) onHandleDragStart;
  final void Function(DragUpdateDetails, double panelHeight) onHandleDragUpdate;
  final void Function(DragEndDetails) onHandleDragEnd;
  final VoidCallback onClose;
  final Future<void> Function() onRefresh;
  final Animation<double> entrance;
  final List<NotificationModel>? items;
  final String? errorMessage;
  final bool Function(NotificationModel) isRead;
  final void Function(NotificationModel) onTapItem;
  final VoidCallback onMarkAllRead;
  final void Function(NotificationModel) onDismissItem;
  final DateTime now;
  final Color paperColor;
  final Color cardColor;
  final Color unreadAccent;
  final Color deleteAccent;

  const _NotificationsPanel({
    required this.onHandleDragStart,
    required this.onHandleDragUpdate,
    required this.onHandleDragEnd,
    required this.onClose,
    required this.onRefresh,
    required this.entrance,
    required this.items,
    required this.errorMessage,
    required this.isRead,
    required this.onTapItem,
    required this.onMarkAllRead,
    required this.onDismissItem,
    required this.now,
    required this.paperColor,
    required this.cardColor,
    required this.unreadAccent,
    required this.deleteAccent,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: paperColor,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SafeArea(
            top: false,
            child: Column(
              children: [
                // [백엔드 수정] 손잡이 막대뿐 아니라 제목줄(알림함~X) 어디를 끌어도 닫히게.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: onHandleDragStart,
                  onVerticalDragUpdate: (d) =>
                      onHandleDragUpdate(d, constraints.maxHeight),
                  onVerticalDragEnd: onHandleDragEnd,
                  child: Column(
                    children: [
                      const SheetGrabHandle(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '알림함',
                                style: TextStyle(
                                  fontSize: context.sp(18),
                                  fontWeight: FontWeight.w900,
                                  color: PaperColors.ink,
                                ),
                              ),
                            ),
                            // [백엔드 수정] 안 읽은 게 있을 때만.
                            if (items?.any((e) => !isRead(e)) ?? false)
                              TextButton(
                                onPressed: onMarkAllRead,
                                style: TextButton.styleFrom(
                                  foregroundColor: PaperColors.muted,
                                ),
                                child: Text(
                                  '모두 읽음',
                                  style: TextStyle(
                                    fontSize: context.sp(13),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            IconButton(
                              onPressed: onClose,
                              icon: const Icon(Icons.close),
                              color: PaperColors.muted,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 1,
                  color: PaperColors.ink.withValues(alpha: 0.08),
                ),
                Expanded(child: _buildBody(context)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (errorMessage != null && items == null) {
      return _EmptyState(
        icon: Icons.wifi_off_rounded,
        message: '알림을 불러오지 못했어요.\n$errorMessage',
      );
    }
    final loaded = items;
    if (loaded == null) {
      return const Center(
        child: CircularProgressIndicator(color: PaperColors.muted),
      );
    }
    if (loaded.isEmpty) {
      return const _EmptyState(
        icon: Icons.notifications_none_rounded,
        message: '아직 도착한 알림이 없어요.\n공연 소식이 생기면 여기에 모아드릴게요.',
      );
    }
    // [백엔드 수정] 당겨서 새로고침 끔 - 아래로 끌어 창 닫는 제스처와 겹쳐서.
    // return RefreshIndicator(
    //   onRefresh: onRefresh,
    //   child: ListView.separated(
    // [백엔드 수정] 오늘/어제/이번 주/이전으로 묶음 - 목록이 최신순이라 묶음이 바뀌는 자리에 제목을 넣음.
    final entries = <Object>[];
    String? group;
    for (final item in loaded) {
      final label = notificationGroupLabel(item.scheduledAt, now);
      if (label != group) {
        entries.add(label);
        group = label;
      }
      entries.add(item);
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(16, 4, 16, context.rs(24)),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry is String) return _GroupHeader(label: entry);
        final item = entry as NotificationModel;
        return Padding(
          padding: EdgeInsets.only(bottom: context.rs(10)),
          child: _CardEntrance(
            key: ValueKey('entrance-${item.id}'),
            animation: entrance,
            index: loaded.indexOf(item),
            child: _NotificationCard(
              key: ValueKey(item.id),
              item: item,
              read: isRead(item),
              cardColor: cardColor,
              unreadAccent: unreadAccent,
              deleteAccent: deleteAccent,
              timeLabel: notificationTimeLabel(item.scheduledAt, now),
              now: now,
              onTap: () => onTapItem(item),
              onDismissed: () => onDismissItem(item),
            ),
          ),
        );
      },
      // ),
    );
  }
}

/// [백엔드 수정] 알림 카드가 위에서부터 차례로 살짝 떠오르며 나타나는 연출.
/// 앞 8장만 시차를 두고, 나머지는 바로 보임(목록이 길어도 오래 기다리지 않게).
class _CardEntrance extends StatelessWidget {
  final Animation<double> animation;
  final int index;
  final Widget child;

  const _CardEntrance({
    super.key,
    required this.animation,
    required this.index,
    required this.child,
  });

  static const int _staggered = 8;
  static const double _step = 0.07;
  static const double _span = 0.45;

  @override
  Widget build(BuildContext context) {
    if (index >= _staggered || MediaQuery.of(context).disableAnimations) {
      return child;
    }
    final start = index * _step;
    final interval = Interval(start, start + _span, curve: Curves.easeOutCubic);
    final rise = context.rs(18);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final v = interval.transform(animation.value);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1 - v) * rise),
            child: child,
          ),
        );
      },
    );
  }
}

/// 알림 한 건을 보여주는 메모 카드. 왼쪽으로 스와이프하면 삭제됨.
class _NotificationCard extends StatelessWidget {
  final NotificationModel item;
  final bool read;
  final Color cardColor;
  final Color unreadAccent;
  final Color deleteAccent;
  final String timeLabel;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback onDismissed;

  const _NotificationCard({
    super.key,
    required this.item,
    required this.read,
    required this.cardColor,
    required this.unreadAccent,
    required this.deleteAccent,
    required this.timeLabel,
    required this.now,
    required this.onTap,
    required this.onDismissed,
  });

  @override
  Widget build(BuildContext context) {
    final kind = NotificationKind.of(item.type);
    return Dismissible(
      key: ValueKey('notification_dismissible_${item.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDismissed(),
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: EdgeInsets.only(right: context.rs(20)),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: deleteAccent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Icon(Icons.delete_outline, color: PaperColors.card),
      ),
      child: PressableScale(
        onTap: onTap,
        pressScale: 0.985,
        tapScale: 1.01,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: PaperColors.ink.withValues(alpha: 0.08)),
            boxShadow: [
              BoxShadow(
                color: PaperColors.ink.withValues(alpha: 0.10),
                blurRadius: 7,
                offset: const Offset(1, 3),
              ),
            ],
          ),
          padding: EdgeInsets.all(context.rs(12)),
          // [백엔드 수정] 포스터 썸네일 + 종류 태그(무슨 알림인지) + 공연명 + 본문 구성으로 바꿈.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _NotificationThumb(kind: kind, posterUrl: item.posterUrl),
              SizedBox(width: context.rs(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _KindTag(kind: kind),
                        const Spacer(),
                        Text(
                          timeLabel,
                          style: TextStyle(
                            fontSize: context.sp(10.5),
                            fontWeight: FontWeight.w600,
                            color: PaperColors.muted,
                          ),
                        ),
                        if (!read) ...[
                          SizedBox(width: context.rs(6)),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              border: Border.all(
                                color: unreadAccent.withValues(alpha: 0.85),
                                width: 1.3,
                              ),
                            ),
                            child: Text(
                              'NEW',
                              style: TextStyle(
                                fontSize: context.sp(8.5),
                                fontWeight: FontWeight.w900,
                                color: unreadAccent,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    SizedBox(height: context.rs(6)),
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.sp(14),
                        fontWeight: read ? FontWeight.w600 : FontWeight.w900,
                        color: PaperColors.ink,
                        height: 1.3,
                      ),
                    ),
                    SizedBox(height: context.rs(3)),
                    Text(
                      // [백엔드 수정] 지난 알림의 "오늘/내일"은 실제 날짜로.
                      notificationInboxBody(
                        item.type,
                        item.body,
                        item.scheduledAt,
                        now,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.sp(12.5),
                        color: PaperColors.ink.withValues(alpha: 0.7),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [백엔드 수정] 카드 왼쪽 썸네일 - 공연 포스터(없거나 못 불러오면 종류 아이콘 타일).
class _NotificationThumb extends StatelessWidget {
  final NotificationKind kind;
  final String? posterUrl;

  const _NotificationThumb({required this.kind, required this.posterUrl});

  @override
  Widget build(BuildContext context) {
    final width = context.rs(46);
    final height = context.rs(62);
    Widget tile() => Container(
      width: width,
      height: height,
      color: kind.color.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Icon(kind.icon, color: kind.color, size: context.rs(22)),
    );
    final url = posterUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: url == null || url.isEmpty
          ? tile()
          : AppNetworkImage(
              url,
              width: width,
              height: height,
              memCacheWidth: 160,
              placeholderBuilder: (_) => tile(),
              errorBuilder: (_) => tile(),
            ),
    );
  }
}

/// [백엔드 수정] 무슨 알림인지 보여주는 작은 색 태그(아이콘 + "내일 공연" 등).
class _KindTag extends StatelessWidget {
  final NotificationKind kind;

  const _KindTag({required this.kind});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: kind.color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(kind.icon, size: context.rs(12), color: kind.color),
          const SizedBox(width: 3),
          Text(
            kind.label,
            style: TextStyle(
              fontSize: context.sp(10.5),
              fontWeight: FontWeight.w800,
              color: kind.color,
            ),
          ),
        ],
      ),
    );
  }
}

/// [백엔드 수정] 오늘/어제/이번 주/이전 묶음 제목.
class _GroupHeader extends StatelessWidget {
  final String label;

  const _GroupHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(4, context.rs(12), 4, context.rs(8)),
      child: Text(
        label,
        style: TextStyle(
          fontSize: context.sp(12),
          fontWeight: FontWeight.w800,
          color: PaperColors.muted,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    // 첫 줄은 제목, 나머지는 본문으로 메모지에 얹음
    final lines = message.split('\n');
    return PaperNotice(
      icon: icon,
      title: lines.first.replaceFirst(RegExp(r'\.$'), ''),
      body: lines.skip(1).join('\n'),
    );
  }
}
