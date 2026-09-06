import 'package:flutter/material.dart';

import '../models/notification_model.dart';
import '../services/api_client.dart';
import '../services/notifications_service.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/responsive_text.dart';

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
    with SingleTickerProviderStateMixin {
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

  bool _isClosing = false;

  /// 손잡이를 드래그해서 직접 닫는 동안엔 컨트롤러 값을 애니메이션이 아니라
  /// 손가락 움직임에 맞춰 직접 정함.
  bool _dragging = false;

  static const Color _paperColor = Color(0xFFF4F1E1);
  static const Color _cardColor = Color(0xFFFAFAFA);
  static const Color _unreadAccent = Color(0xFFE0455E);
  static const Color _deleteAccent = Color(0xFFE4002B);

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
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _errorMessage = null);
    try {
      final items = await _service.list();
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      final message = e is ApiException
          ? '오류 (${e.statusCode})'
          : '오류 (연결 실패)';
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

  static String _formatDateTime(DateTime raw) {
    final date = raw.toLocal();
    final y = date.year;
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    final hh = date.hour.toString().padLeft(2, '0');
    final mm = date.minute.toString().padLeft(2, '0');
    return '$y.$m.$d $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    return DiaryFrameScale(
      scale: widget.frameScale,
      marginEachSide: 0,
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
          items: _items,
          errorMessage: _errorMessage,
          isRead: _isRead,
          onTapItem: _markRead,
          onDismissItem: _delete,
          formatDateTime: _formatDateTime,
          paperColor: _paperColor,
          cardColor: _cardColor,
          unreadAccent: _unreadAccent,
          deleteAccent: _deleteAccent,
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
  final List<NotificationModel>? items;
  final String? errorMessage;
  final bool Function(NotificationModel) isRead;
  final void Function(NotificationModel) onTapItem;
  final void Function(NotificationModel) onDismissItem;
  final String Function(DateTime) formatDateTime;
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
    required this.items,
    required this.errorMessage,
    required this.isRead,
    required this.onTapItem,
    required this.onDismissItem,
    required this.formatDateTime,
    required this.paperColor,
    required this.cardColor,
    required this.unreadAccent,
    required this.deleteAccent,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: paperColor,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SafeArea(
            top: false,
            child: Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: onHandleDragStart,
                  onVerticalDragUpdate: (d) =>
                      onHandleDragUpdate(d, constraints.maxHeight),
                  onVerticalDragEnd: onHandleDragEnd,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 4),
                    child: Center(
                      child: Container(
                        width: context.rs(40),
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
                ),
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
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: onClose,
                        icon: const Icon(Icons.close),
                        color: Colors.black.withValues(alpha: 0.55),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 1,
                  color: Colors.black.withValues(alpha: 0.08),
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
      return const Center(child: CircularProgressIndicator());
    }
    if (loaded.isEmpty) {
      return const _EmptyState(
        icon: Icons.notifications_none_rounded,
        message: '아직 도착한 알림이 없어요.\n공연 소식이 생기면 여기에 모아드릴게요.',
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(16, 14, 16, context.rs(24)),
        itemCount: loaded.length,
        separatorBuilder: (context, index) => SizedBox(height: context.rs(10)),
        itemBuilder: (context, index) {
          final item = loaded[index];
          return _NotificationCard(
            key: ValueKey(item.id),
            item: item,
            read: isRead(item),
            cardColor: cardColor,
            unreadAccent: unreadAccent,
            deleteAccent: deleteAccent,
            timeLabel: formatDateTime(item.scheduledAt),
            onTap: () => onTapItem(item),
            onDismissed: () => onDismissItem(item),
          );
        },
      ),
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
    required this.onTap,
    required this.onDismissed,
  });

  @override
  Widget build(BuildContext context) {
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
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      child: PressableScale(
        onTap: onTap,
        pressScale: 0.985,
        tapScale: 1.01,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          padding: EdgeInsets.all(context.rs(14)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      item.title,
                      style: TextStyle(
                        fontSize: context.sp(14),
                        fontWeight: read ? FontWeight.w600 : FontWeight.w900,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  if (!read) ...[
                    SizedBox(width: context.rs(8)),
                    Container(
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: unreadAccent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'NEW',
                        style: TextStyle(
                          fontSize: context.sp(8.5),
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              SizedBox(height: context.rs(4)),
              Text(
                item.body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.sp(12.5),
                  color: Colors.black.withValues(alpha: 0.65),
                  height: 1.35,
                ),
              ),
              SizedBox(height: context.rs(8)),
              Text(
                timeLabel,
                style: TextStyle(
                  fontSize: context.sp(10.5),
                  fontWeight: FontWeight.w600,
                  color: Colors.black.withValues(alpha: 0.35),
                ),
              ),
            ],
          ),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: Colors.black.withValues(alpha: 0.22)),
            SizedBox(height: context.rs(10)),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.sp(13),
                color: Colors.black.withValues(alpha: 0.5),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
