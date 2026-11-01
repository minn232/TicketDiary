import 'package:flutter/material.dart';

import '../models/connection.dart';
import '../services/api_client.dart';
import '../services/connection_service.dart';
import '../widgets/connection_card_view.dart';
import '../widgets/liquid_rise.dart';
import '../widgets/responsive_text.dart';
import '../widgets/sheet_grab_handle.dart';

// [백엔드 수정]
// 흔들어 만난 친구와의 일회용 카드. 맞대기 화면에서 떨어진 물방울이 패널 자리에 차오르고,
// 다 덮이면 카드가 나타남. 저장하지 않아 닫으면 다시 볼 수 없음(서버도 연결 뒤 10분만 줌).
class MeetingCardScreen extends StatefulWidget {
  final double frameScale;
  final ConnectionPeer peer;
  // 맞대기 화면이 미리 받아 둔 카드(못 받았으면 null - 여기서 받음)
  final ConnectionCard? card;
  final ConnectionService? service;

  const MeetingCardScreen({
    super.key,
    required this.frameScale,
    required this.peer,
    this.card,
    this.service,
  });

  static Future<void> show(
    BuildContext context, {
    required double frameScale,
    required ConnectionPeer peer,
    ConnectionCard? card,
    ConnectionService? service,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'meeting_card_overlay',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) =>
          MeetingCardScreen(
            frameScale: frameScale,
            peer: peer,
            card: card,
            service: service,
          ),
    );
  }

  @override
  State<MeetingCardScreen> createState() => _MeetingCardScreenState();
}

class _MeetingCardScreenState extends State<MeetingCardScreen>
    with TickerProviderStateMixin {
  late final ConnectionService _service = widget.service ?? ConnectionService();
  // 물이 차오르는 동안은 패널 대신 물만 보임
  late final AnimationController _flood;
  // 닫을 때 패널이 아래로 내려감(열 때는 물이 대신함)
  late final AnimationController _panel;
  bool _covered = false;
  bool _isClosing = false;

  ConnectionCard? _card;
  String? _error;
  bool _expired = false;

  static const Color _paperColor = Color(0xFFF4F1E1);
  static const Color _accent = Color(0xFF8B5E3C);

  @override
  void initState() {
    super.initState();
    _card = widget.card;
    _panel = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _flood = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..addListener(_showWhenCovered);
    _flood.forward();
    if (_card == null) _loadCard();
  }

  @override
  void dispose() {
    _flood.dispose();
    _panel.dispose();
    super.dispose();
  }

  void _showWhenCovered() {
    if (_covered || _flood.value < LiquidFlood.coveredAt) return;
    setState(() => _covered = true);
  }

  Future<void> _loadCard() async {
    setState(() {
      _error = null;
      _expired = false;
    });
    try {
      final card = await _service.getCard(widget.peer.userId);
      if (mounted) setState(() => _card = card);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // 연결 뒤 10분이 지났거나(410) 상대가 그새 다시 맞대 새 시도가 됨(404)
        _expired =
            e is ApiException && (e.statusCode == 410 || e.statusCode == 404);
        _error = e is ApiException ? '오류 (${e.statusCode})' : '오류 (연결 실패)';
      });
    }
  }

  Future<void> _close() async {
    if (_isClosing) return;
    _isClosing = true;
    try {
      await _panel.reverse();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = CurvedAnimation(parent: _panel, curve: Curves.easeOutCubic);
    return DiaryFrameScale(
      scale: widget.frameScale,
      marginEachSide: 0,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _close();
        },
        child: AnimatedBuilder(
          animation: Listenable.merge([t, _flood]),
          builder: (context, child) {
            // 배경은 물이 차오르는 만큼 어두워짐
            final dim = _covered ? 1.0 : (_flood.value / LiquidFlood.coveredAt);
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _covered ? _close : null,
                    child: Container(
                      color: Colors.black.withValues(
                        alpha: 0.45 * dim.clamp(0.0, 1.0) * t.value,
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 0.9,
                    child: FractionalTranslation(
                      translation: Offset(0, 1 - t.value),
                      child: child,
                    ),
                  ),
                ),
              ],
            );
          },
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            child: Stack(
              children: [
                if (_covered)
                  Positioned.fill(
                    child: Material(
                      color: _paperColor,
                      child: SafeArea(
                        top: false,
                        child: Column(
                          children: [
                            const SheetGrabHandle(),
                            Builder(builder: _buildHeader),
                            Container(
                              height: 1,
                              color: Colors.black.withValues(alpha: 0.08),
                            ),
                            Expanded(child: Builder(builder: _buildCard)),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (!_flood.isCompleted)
                  Positioned.fill(
                    child: LiquidFlood(
                      animation: _flood,
                      color: _accent,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.peer.displayName,
                  style: TextStyle(
                    fontSize: context.sp(18),
                    fontWeight: FontWeight.w900,
                    color: Colors.black87,
                  ),
                ),
                Text(
                  '지금만 볼 수 있어요. 닫으면 사라져요',
                  style: TextStyle(
                    fontSize: context.sp(11),
                    color: Colors.black45,
                  ),
                ),
              ],
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
    final card = _card;
    if (card != null) return ConnectionCardView(card: card);
    if (_error == null) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        children: [
          Icon(
            _expired ? Icons.timer_off_outlined : Icons.wifi_off_rounded,
            size: 40,
            color: Colors.black.withValues(alpha: 0.22),
          ),
          SizedBox(height: context.rs(10)),
          Text(
            _expired
                ? '카드를 볼 수 있는 시간이 지났어요.\n다시 흔들어 맞대주세요.'
                : '카드를 불러오지 못했어요.\n$_error',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(13),
              color: Colors.black.withValues(alpha: 0.5),
              height: 1.4,
            ),
          ),
          if (!_expired) ...[
            SizedBox(height: context.rs(14)),
            OutlinedButton(onPressed: _loadCard, child: const Text('다시 시도')),
          ],
        ],
      ),
    );
  }
}
