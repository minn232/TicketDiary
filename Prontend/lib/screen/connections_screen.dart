import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/connection.dart';
import '../services/api_client.dart';
import '../services/connection_service.dart';
import '../widgets/app_network_image.dart';
import '../widgets/connection_card_view.dart';
import '../widgets/liquid_rise.dart';
import '../widgets/pressable_scale.dart';
import '../widgets/responsive_text.dart';
import 'nearby_tap_screen.dart';

// [백엔드 수정]
// 연결된 친구 목록 + 연결 카드. 알림함과 같은 슬라이드업 패널.
class ConnectionsScreen extends StatefulWidget {
  final double frameScale;

  /// 바로 이 상대의 카드를 열고 시작 (맞대기로 막 연결됐을 때).
  final ConnectionPeer? initialPeer;
  final ConnectionService? service;

  const ConnectionsScreen({
    super.key,
    required this.frameScale,
    this.initialPeer,
    this.service,
  });

  static Future<void> show(
    BuildContext context, {
    required double frameScale,
    ConnectionPeer? initialPeer,
    ConnectionService? service,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'connections_overlay',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (context, animation, secondaryAnimation) =>
          ConnectionsScreen(
            frameScale: frameScale,
            initialPeer: initialPeer,
            service: service,
          ),
    );
  }

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen>
    with TickerProviderStateMixin {
  late final ConnectionService _service = widget.service ?? ConnectionService();
  late final AnimationController _controller;
  late final Animation<double> _t;
  bool _isClosing = false;

  List<UserConnection>? _connections;
  String? _listError;
  bool? _shareNext;

  // 카드를 보고 있는 상대 (null이면 목록)
  ConnectionPeer? _openPeer;
  // 맞대기로 막 연결되면 떨어진 물방울이 패널에 고여 차오름 - 다 덮였을 때 카드로 바꾸고 물이 걷힘
  late final AnimationController _flood;
  bool _flooding = false;
  ({ConnectionPeer peer, ConnectionCard? card})? _pendingOpen;
  ConnectionCard? _card;
  String? _cardError;

  static const Color _paperColor = Color(0xFFF4F1E1);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _t = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.forward();
    _flood = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..addListener(_openWhenCovered);
    _loadList();
    _loadShareSetting();
    if (widget.initialPeer != null) _openCard(widget.initialPeer!);
  }

  @override
  void dispose() {
    _controller.dispose();
    _flood.dispose();
    super.dispose();
  }

  String _errorText(Object e) =>
      e is ApiException ? '오류 (${e.statusCode})' : '오류 (연결 실패)';

  Future<void> _loadList() async {
    setState(() => _listError = null);
    try {
      final list = await _service.listConnections();
      if (mounted) setState(() => _connections = list);
    } catch (e) {
      if (mounted) setState(() => _listError = _errorText(e));
    }
  }

  Future<void> _loadShareSetting() async {
    try {
      final value = await _service.getShareNextConcert();
      if (mounted) setState(() => _shareNext = value);
    } catch (_) {}
  }

  Future<void> _setShareNext(bool value) async {
    final previous = _shareNext;
    setState(() => _shareNext = value);
    try {
      await _service.setShareNextConcert(value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _shareNext = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('설정을 바꾸지 못했어요: ${_errorText(e)}')));
    }
  }

  Future<void> _openCard(ConnectionPeer peer) async {
    setState(() {
      _openPeer = peer;
      _card = null;
      _cardError = null;
    });
    // 로딩 중 다른 친구로 바꿨으면 늦게 온 응답은 버림
    bool stillOpen() => mounted && _openPeer?.userId == peer.userId;
    try {
      final card = await _service.getCard(peer.userId);
      if (stillOpen()) setState(() => _card = card);
    } catch (e) {
      if (stillOpen()) setState(() => _cardError = _errorText(e));
    }
  }

  // 물이 패널을 다 덮은 순간 그 아래에서 목록을 카드로 바꿈
  void _openWhenCovered() {
    final pending = _pendingOpen;
    if (pending == null || _flood.value < LiquidFlood.coveredAt) return;
    _pendingOpen = null;
    if (pending.card == null) {
      _openCard(pending.peer);
      return;
    }
    setState(() {
      _openPeer = pending.peer;
      _card = pending.card;
      _cardError = null;
    });
  }

  void _backToList() {
    setState(() => _openPeer = null);
    // 상대가 그사이 연결을 끊었을 수 있어 다시 불러옴
    _loadList();
  }

  Future<void> _startNearbyTap(BuildContext context) async {
    final peer = await NearbyTapScreen.show(
      context,
      frameScale: widget.frameScale,
      // 떨어진 물방울이 패널 바닥에 닿는 순간 - 물이 차올라 다 덮이면 카드로 바뀜
      onConnected: (peer, card) {
        if (!mounted) return;
        _pendingOpen = (peer: peer, card: card);
        setState(() => _flooding = true);
        _flood.forward(from: 0).whenComplete(() {
          if (mounted) setState(() => _flooding = false);
        });
      },
    );
    if (!mounted) return;
    await _loadList();
    if (peer != null &&
        _openPeer?.userId != peer.userId &&
        _pendingOpen?.peer.userId != peer.userId) {
      _openCard(peer);
    }
  }

  Future<void> _confirmDisconnect(UserConnection connection) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${connection.peer.displayName}님과 연결을 끊을까요?'),
        content: const Text('다시 폰을 맞대면 새로 연결할 수 있어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('연결 끊기'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.deleteConnection(connection.peer.userId);
      if (!mounted) return;
      setState(() => _connections?.remove(connection));
    } catch (e) {
      // 상대가 먼저 끊었으면(404) 목록만 맞춤
      if (e is ApiException && e.statusCode == 404) {
        if (mounted) await _loadList();
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('연결을 끊지 못했어요: ${_errorText(e)}')));
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

  @override
  Widget build(BuildContext context) {
    return DiaryFrameScale(
      scale: widget.frameScale,
      marginEachSide: 0,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          // 카드를 보고 있으면 목록으로, 목록이면 닫기
          if (_openPeer != null && widget.initialPeer == null) {
            _backToList();
          } else {
            _close();
          }
        },
        child: AnimatedBuilder(
          animation: _t,
          builder: (context, child) {
            final t = _t.value;
            return Stack(
              children: [
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
          child: Material(
            color: _paperColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      Builder(builder: _buildHeader),
                      Container(
                        height: 1,
                        color: Colors.black.withValues(alpha: 0.08),
                      ),
                      Expanded(
                        child: AnimatedSwitcher(
                          // 물에 덮인 동안 바뀌면 바로(어차피 안 보임), 목록에서 열면 아래에서 올라옴
                          duration: Duration(milliseconds: _flooding ? 1 : 480),
                          reverseDuration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          transitionBuilder: (child, animation) =>
                              child.key == const ValueKey('list')
                              ? FadeTransition(opacity: animation, child: child)
                              : SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0, 1),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                          child: _openPeer == null
                              ? KeyedSubtree(
                                  key: const ValueKey('list'),
                                  child: Builder(builder: _buildList),
                                )
                              : KeyedSubtree(
                                  key: ValueKey(_openPeer!.userId),
                                  child: Builder(builder: _buildCard),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 제목줄까지 패널 전체를 덮으며 차오르는 물 (패널 모서리로 잘림)
                if (_flooding)
                  Positioned.fill(
                    child: LiquidFlood(
                      animation: _flood,
                      color: const Color(0xFF8B5E3C),
                      fillColor: _paperColor,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final showBack = _openPeer != null && widget.initialPeer == null;
    return Padding(
      padding: EdgeInsets.fromLTRB(showBack ? 4 : 20, 14, 8, 8),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              onPressed: _backToList,
              icon: const Icon(Icons.arrow_back),
              color: Colors.black.withValues(alpha: 0.55),
            ),
          Expanded(
            child: Text(
              _openPeer == null ? '연결된 친구' : _openPeer!.displayName,
              style: TextStyle(
                fontSize: context.sp(18),
                fontWeight: FontWeight.w900,
                color: Colors.black87,
              ),
            ),
          ),
          IconButton(
            onPressed: _close,
            icon: const Icon(Icons.close),
            color: Colors.black.withValues(alpha: 0.55),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    if (_cardError != null) {
      return _EmptyState(
        icon: Icons.wifi_off_rounded,
        message: '카드를 불러오지 못했어요.\n$_cardError',
      );
    }
    final card = _card;
    if (card == null) return const Center(child: CircularProgressIndicator());
    return ConnectionCardView(card: card);
  }

  Widget _buildList(BuildContext context) {
    final connections = _connections;
    return RefreshIndicator(
      onRefresh: _loadList,
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, context.rs(24)),
        children: [
          // 폰 맞대기는 안드로이드만 (iOS는 서드파티 BLE 광고 제약)
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            Padding(
              padding: EdgeInsets.only(bottom: context.rs(6)),
              child: FilledButton.icon(
                onPressed: () => _startNearbyTap(context),
                icon: const Icon(Icons.tap_and_play_rounded),
                label: const Text('폰 맞대서 친구 연결'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF8B5E3C),
                  minimumSize: Size.fromHeight(context.rs(48)),
                ),
              ),
            ),
          if (_shareNext != null)
            SwitchListTile.adaptive(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text(
                '내 다음 공연 보여주기',
                style: TextStyle(
                  fontSize: context.sp(14),
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: Text(
                '끄면 친구에겐 둘 다 예매한 공연만 보여요',
                style: TextStyle(
                  fontSize: context.sp(11.5),
                  color: Colors.black45,
                ),
              ),
              value: _shareNext!,
              onChanged: _setShareNext,
              activeThumbColor: const Color(0xFF4E8F5A),
              activeTrackColor: const Color(0xFF7FB77E),
            ),
          SizedBox(height: context.rs(6)),
          if (_listError != null && connections == null)
            _EmptyState(
              icon: Icons.wifi_off_rounded,
              message: '친구 목록을 불러오지 못했어요.\n$_listError',
            )
          else if (connections == null)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (connections.isEmpty)
            const _EmptyState(
              icon: Icons.people_outline_rounded,
              message: '아직 연결된 친구가 없어요.\n친구와 폰 윗부분을 맞대면 연결돼요.',
            )
          else
            for (final c in connections)
              Padding(
                padding: EdgeInsets.only(bottom: context.rs(10)),
                child: _ConnectionTile(
                  connection: c,
                  onTap: () => _openCard(c.peer),
                  onLongPress: () => _confirmDisconnect(c),
                ),
              ),
        ],
      ),
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  final UserConnection connection;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ConnectionTile({
    required this.connection,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final peer = connection.peer;
    final met = (connection.lastMetAt ?? connection.connectedAt).toLocal();
    final metLabel =
        '${met.year}.${met.month.toString().padLeft(2, '0')}.${met.day.toString().padLeft(2, '0')}';
    final avatarSize = context.rs(44);
    final initial = Container(
      width: avatarSize,
      height: avatarSize,
      color: const Color(0xFFE8DFC8),
      alignment: Alignment.center,
      child: Text(
        peer.displayName.characters.first,
        style: TextStyle(
          fontSize: context.sp(16),
          fontWeight: FontWeight.w900,
          color: const Color(0xFF8B5E3C),
        ),
      ),
    );
    return GestureDetector(
      onLongPress: onLongPress,
      child: PressableScale(
        onTap: onTap,
        pressScale: 0.985,
        tapScale: 1.01,
        child: Container(
          padding: EdgeInsets.all(context.rs(12)),
          decoration: BoxDecoration(
            color: const Color(0xFFFAFAFA),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.056),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              ClipOval(
                child: peer.profileImageUrl == null
                    ? initial
                    : AppNetworkImage(
                        peer.profileImageUrl!,
                        width: avatarSize,
                        height: avatarSize,
                        placeholderBuilder: (_) => initial,
                        errorBuilder: (_) => initial,
                      ),
              ),
              SizedBox(width: context.rs(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.displayName,
                      style: TextStyle(
                        fontSize: context.sp(15),
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                      ),
                    ),
                    Text(
                      '마지막으로 만난 날 $metLabel',
                      style: TextStyle(
                        fontSize: context.sp(11),
                        color: Colors.black45,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Colors.black.withValues(alpha: 0.45),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
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
    );
  }
}
