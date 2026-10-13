import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/connection.dart';
import '../services/api_client.dart';
import '../services/connection_service.dart';
import '../services/nearby_tap_engine.dart';
import '../widgets/app_network_image.dart';
import '../widgets/nearby_peer_reveal.dart';
import '../widgets/responsive_text.dart';

// [백엔드 수정]
// 폰 맞대기로 친구 연결. 연결되면 상대 프로필을 돌려줌(안드로이드 전용).
class NearbyTapScreen extends StatefulWidget {
  final double frameScale;
  // 연결 뒤 물방울이 화면 밖으로 나갈 즈음 호출, 미리 불러온 공유 카드(실패면 null)를 넘김
  final void Function(ConnectionPeer peer, ConnectionCard? card)? onConnected;

  const NearbyTapScreen({
    super.key,
    required this.frameScale,
    this.onConnected,
  });

  static Future<ConnectionPeer?> show(
    BuildContext context, {
    required double frameScale,
    void Function(ConnectionPeer peer, ConnectionCard? card)? onConnected,
  }) {
    return showGeneralDialog<ConnectionPeer>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'nearby_tap_overlay',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (context, animation, secondaryAnimation) =>
          NearbyTapScreen(frameScale: frameScale, onConnected: onConnected),
    );
  }

  @override
  State<NearbyTapScreen> createState() => _NearbyTapScreenState();
}

enum _Phase {
  preparing,
  searching,
  checking,
  confirm,
  waitingPeer,
  connected,
  failed,
}

class _NearbyTapScreenState extends State<NearbyTapScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _service = ConnectionService();
  final _engine = NearbyTapEngine();
  StreamSubscription<NearbyDetection>? _detectionSub;
  late final AnimationController _slide;
  late final AnimationController _pulse;
  // 상대를 찾으면 윗면에서 카드가 펼쳐져 나옴 - 그동안 아래 시트는 내려감
  late final AnimationController _reveal;
  // 연결 완료 뒤 윗면 카드가 물방울로 오므라들어 떨어짐
  late final AnimationController _handoff;
  bool _isClosing = false;

  _Phase _phase = _Phase.preparing;
  String? _message;
  String? _myCode;
  // 확인 중인 연결 요청
  ConnectionRequest? _request;
  // 윗면 카드에 띄운 요청 - 다시 찾기로 돌아가도 카드가 들어갈 때까지 남겨둠
  ConnectionRequest? _revealRequest;
  // 이미 연결된 친구를 다시 만난 것 (문구만 다름)
  bool _reMeet = false;
  Timer? _poll;
  bool _reporting = false;

  static const Color _paperColor = Color(0xFFF4F1E1);
  static const Color _accent = Color(0xFF8B5E3C);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _slide = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 220),
    )..forward();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
      reverseDuration: const Duration(milliseconds: 420),
    );
    _handoff = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    );
    _engine.addListener(_onEngineChanged);
    _detectionSub = _engine.detections.listen(_onDetected);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _detectionSub?.cancel();
    _engine.removeListener(_onEngineChanged);
    _engine.dispose();
    _slide.dispose();
    _pulse.dispose();
    _reveal.dispose();
    _handoff.dispose();
    super.dispose();
  }

  // 화면이 꺼지거나 다른 앱으로 가면 광고/스캔을 멈추고, 돌아오면 다시 시작
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _engine.stop();
    } else if (state == AppLifecycleState.resumed &&
        _myCode != null &&
        _phase == _Phase.searching) {
      _engine.start(_myCode!);
    }
  }

  void _onEngineChanged() {
    if (!mounted) return;
    final error = _engine.error;
    if (error != null && _phase != _Phase.failed) {
      _fail(switch (error) {
        NearbyEngineError.unsupported => '이 기기는 폰 맞대기를 지원하지 않아요.',
        NearbyEngineError.permissionDenied => '근처 기기(블루투스) 권한을 허용해주세요.',
        NearbyEngineError.bluetoothOff => '블루투스를 켜주세요.',
        NearbyEngineError.locationOff => '이 기기는 위치(GPS)를 켜야 근처 기기를 찾을 수 있어요.',
        NearbyEngineError.failed => '근처 기기를 찾지 못했어요. 다시 시도해주세요.',
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.preparing;
      _message = null;
    });
    unawaited(_service.flushQueuedSightings());
    final code = await _service.getNearbyCode();
    if (!mounted) return;
    if (code == null) {
      _fail('인터넷에 연결된 상태로 한 번 열어주세요.');
      return;
    }
    _myCode = code;
    await _engine.start(code);
    if (!mounted || _engine.error != null) return;
    setState(() => _phase = _Phase.searching);
  }

  void _fail(String message) {
    _engine.stop();
    setState(() {
      _phase = _Phase.failed;
      _message = message;
    });
  }

  Future<void> _onDetected(NearbyDetection detection) async {
    // 상대 판정 대기 중(checking)에도 더 강해진 판정은 다시 올림
    if (_reporting ||
        (_phase != _Phase.searching && _phase != _Phase.checking)) {
      return;
    }
    _reporting = true;
    setState(() {
      _phase = _Phase.checking;
      _message = null;
    });
    try {
      final result = await _service.reportSighting(
        code: detection.code,
        rssi: detection.rssi,
        seenAt: detection.seenAt,
      );
      if (!mounted) return;
      if (result == null) {
        _backToSearching('인터넷이 연결되면 연결 요청을 확인할 수 있어요.');
      } else if (result.status == 'connected') {
        _finish(result.peer!);
      } else if (result.status == 'pending') {
        _showRequest(
          ConnectionRequest(
            connectionId: result.connectionId!,
            peer: result.peer!,
            requestedAt: DateTime.now(),
            confirmedByMe: result.confirmedByMe,
          ),
        );
      } else {
        _waitForPeerSighting();
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _backToSearching(
        e.statusCode == 404
            ? '친구 폰의 맞대기 정보가 오래됐어요. 친구도 화면을 다시 열어주세요.'
            : '연결하지 못했어요 (${e.statusCode}).',
      );
    } finally {
      _reporting = false;
    }
  }

  // 상대 판정 대기 - 새 연결 요청이 생기거나, 이미 연결된 사이면 연결 목록의 만남 시각(last_met_at)이
  // 바뀌면 완료
  void _waitForPeerSighting() {
    var tries = 0;
    _poll?.cancel();
    final startedAt = DateTime.now().toUtc();
    Map<String, DateTime?>? metBefore;
    _poll = Timer.periodic(const Duration(seconds: 1), (timer) async {
      tries++;
      try {
        final requests = await _service.listRequests();
        final fresh = requests.where(
          (r) =>
              DateTime.now().difference(r.requestedAt.toLocal()).inSeconds < 90,
        );
        if (!mounted || _phase != _Phase.checking) return timer.cancel();
        if (fresh.isNotEmpty) {
          timer.cancel();
          _showRequest(fresh.first);
          return;
        }
        final connections = await _service.listConnections();
        if (!mounted || _phase != _Phase.checking) return timer.cancel();
        // 처음 본 만남 시각과 달라졌거나(기기·서버 시계 차이와 무관), 방금(30초 안) 만난 사이
        final before = metBefore ??= {
          for (final c in connections) c.peer.userId: c.lastMetAt,
        };
        final met = connections.where((c) {
          final at = c.lastMetAt;
          if (at == null) return false;
          final changed = before.containsKey(c.peer.userId)
              ? before[c.peer.userId] != at
              : true;
          return changed ||
              startedAt.difference(at.toUtc()).inSeconds.abs() < 30;
        });
        if (met.isNotEmpty) {
          timer.cancel();
          _finish(met.first.peer);
          return;
        }
      } catch (_) {}
      if (tries >= 12) {
        timer.cancel();
        if (mounted) _backToSearching('친구 폰에서도 맞대기 화면이 켜져 있는지 확인하고 다시 맞대주세요.');
      }
    });
  }

  void _showRequest(ConnectionRequest request) {
    setState(() {
      _request = request;
      _revealRequest = request;
      _phase = request.confirmedByMe ? _Phase.waitingPeer : _Phase.confirm;
    });
    if (_reveal.status != AnimationStatus.forward &&
        _reveal.status != AnimationStatus.completed) {
      HapticFeedback.mediumImpact();
      _reveal.forward();
    }
    if (request.confirmedByMe) _waitForPeerConfirm();
  }

  void _backToSearching(String? message) {
    _poll?.cancel();
    setState(() {
      _phase = _Phase.searching;
      _message = message;
      _request = null;
    });
    _reveal.reverse();
  }

  Future<void> _confirm() async {
    final request = _request;
    if (request == null) return;
    try {
      final connected = await _service.confirmRequest(request.connectionId);
      if (!mounted) return;
      if (connected) {
        _finish(request.peer);
      } else {
        setState(() => _phase = _Phase.waitingPeer);
        _waitForPeerConfirm();
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _backToSearching(
        e.statusCode == 410
            ? '요청이 만료됐어요. 폰을 뗐다가 다시 맞대주세요.'
            : '연결하지 못했어요 (${e.statusCode}).',
      );
    }
  }

  Future<void> _reject() async {
    final request = _request;
    if (request == null) return;
    try {
      await _service.rejectRequest(request.connectionId);
    } catch (_) {}
    if (!mounted) return;
    _backToSearching(null);
  }

  // 내가 확인한 뒤 상대 확인 대기 - 확인을 1.5초마다 다시 보내 연결되면 완료, 404/410이면 거절/만료
  void _waitForPeerConfirm() {
    final request = _request!;
    var tries = 0;
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (timer) async {
      tries++;
      try {
        final connected = await _service.confirmRequest(request.connectionId);
        if (!mounted || _phase != _Phase.waitingPeer) return timer.cancel();
        if (connected) {
          timer.cancel();
          _finish(request.peer);
          return;
        }
      } on ApiException catch (e) {
        if (!mounted || _phase != _Phase.waitingPeer) return timer.cancel();
        // 404 = 상대가 거절해 요청이 지워짐, 410 = 만료
        if (e.statusCode == 404 || e.statusCode == 410) {
          timer.cancel();
          _backToSearching(
            e.statusCode == 404
                ? '${request.peer.displayName}님이 연결하지 않았어요.'
                : '요청이 만료됐어요. 폰을 뗐다가 다시 맞대주세요.',
          );
          return;
        }
      } catch (_) {}
      if (tries >= 400) timer.cancel(); // 10분 뒤 요청이 만료되므로 그만 확인
    });
  }

  // 연결 완료 - "연결됐어요"(이미 연결된 사이면 "다시 만났어요")를 보여주며 공유 카드를 미리 받고,
  // 끝날 때까지 광고를 유지한 뒤 물방울로 떨어짐
  Future<void> _finish(ConnectionPeer peer) async {
    _poll?.cancel();
    if (!mounted) return;
    final reMeet = _revealRequest == null;
    HapticFeedback.lightImpact();
    setState(() {
      _phase = _Phase.connected;
      _reMeet = reMeet;
      _revealRequest ??= ConnectionRequest(
        connectionId: '',
        peer: peer,
        requestedAt: DateTime.now(),
        confirmedByMe: true,
      );
    });
    if (reMeet) {
      HapticFeedback.mediumImpact();
      _reveal.forward();
    }
    final cardFuture = _service
        .getCard(peer.userId)
        .then<ConnectionCard?>((card) => card)
        .timeout(const Duration(seconds: 4), onTimeout: () => null)
        .catchError((_) => null);
    // 다시 만난 경우는 카드가 펼쳐지는 시간까지 더 보여줌
    await Future<void>.delayed(Duration(milliseconds: reMeet ? 2200 : 1100));
    final card = await cardFuture;
    await _engine.stop();
    if (!mounted) return;
    await _dropAway(peer, card);
  }

  // 카드가 물방울로 오므라들어 아래로 떨어지는 동안 어두운 배경이 걷히고, 물방울이 화면 밖으로
  // 나갈 즈음 뒤 화면에 공유 카드를 띄움(그쪽은 아래에서 올라옴)
  Future<void> _dropAway(ConnectionPeer peer, ConnectionCard? card) async {
    if (_isClosing) return;
    _isClosing = true;
    final drop = _handoff.forward();
    await Future<void>.delayed(const Duration(milliseconds: 420));
    final barrier = _slide.reverse();
    // 물방울이 화면 아래끝에 닿을 즈음(떨어짐 약 90%) - 그 자리에서 공유 카드가 차오름
    await Future<void>.delayed(const Duration(milliseconds: 480));
    if (mounted) widget.onConnected?.call(peer, card);
    try {
      await Future.wait([drop, barrier]);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop(peer);
  }

  Future<void> _close({ConnectionPeer? result}) async {
    if (_isClosing) return;
    _isClosing = true;
    try {
      await Future.wait([
        _slide.reverse(),
        if (!_reveal.isDismissed) _reveal.reverse(),
      ]);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final t = CurvedAnimation(parent: _slide, curve: Curves.easeOutCubic);
    // 윗면 카드가 나오기 시작하면 아래 시트는 먼저 내려감
    final sheetAway = CurvedAnimation(
      parent: _reveal,
      curve: const Interval(0, 0.3, curve: Curves.easeInCubic),
    );
    return DiaryFrameScale(
      scale: widget.frameScale,
      marginEachSide: 0,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _close();
        },
        child: AnimatedBuilder(
          animation: Listenable.merge([t, sheetAway]),
          builder: (context, child) => Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: _close,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.45 * t.value),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  heightFactor: 0.75,
                  child: FractionalTranslation(
                    translation: Offset(0, 1 - t.value + sheetAway.value),
                    child: child,
                  ),
                ),
              ),
              if (_revealRequest != null)
                Positioned.fill(
                  child: IgnorePointer(
                    // 들어가는 중인 카드의 버튼은 누를 수 없게
                    ignoring: _reveal.status == AnimationStatus.reverse,
                    child: NearbyPeerReveal(
                      animation: _reveal,
                      exit: _handoff,
                      color: _accent,
                      cardColor: _paperColor,
                      child: _buildPeerCard(context, _revealRequest!),
                    ),
                  ),
                ),
            ],
          ),
          child: Material(
            color: _paperColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: IconButton(
                        onPressed: _close,
                        icon: const Icon(Icons.close),
                        color: Colors.black.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Builder(builder: _buildBody),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final searching = _phase == _Phase.searching || _phase == _Phase.checking;
    final title = switch (_phase) {
      _Phase.preparing => '준비 중이에요',
      _Phase.failed => '연결할 수 없어요',
      _Phase.checking => '친구를 확인하고 있어요',
      _ => '친구와 폰 윗부분을 맞대주세요',
    };
    final sub = _phase == _Phase.failed ? _message : '친구도 이 화면을 열어둬야 해요';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: context.rs(160),
          height: context.rs(160),
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => CustomPaint(
              painter: _PulsePainter(
                progress: searching ? _pulse.value : 0,
                color: _accent,
              ),
              child: Center(
                child: Icon(
                  _phase == _Phase.failed
                      ? Icons.portable_wifi_off_rounded
                      : Icons.tap_and_play_rounded,
                  size: context.rs(56),
                  color: _accent,
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: context.rs(24)),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: context.sp(18),
            fontWeight: FontWeight.w900,
            color: Colors.black87,
          ),
        ),
        SizedBox(height: context.rs(8)),
        if (sub != null)
          Text(
            sub,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(13),
              color: Colors.black54,
              height: 1.4,
            ),
          ),
        if (_phase != _Phase.failed && _message != null) ...[
          SizedBox(height: context.rs(12)),
          Text(
            _message!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(12),
              color: const Color(0xFFE0455E),
              height: 1.4,
            ),
          ),
        ],
        if (_phase == _Phase.failed) ...[
          SizedBox(height: context.rs(18)),
          OutlinedButton(onPressed: _start, child: const Text('다시 시도')),
        ],
      ],
    );
  }

  // 윗면에서 펼쳐지는 상대 카드 - 확인 버튼 / 상대 확인 대기 / 연결됐어요(체크 표시)
  Widget _buildPeerCard(BuildContext context, ConnectionRequest request) {
    final peer = request.peer;
    final size = context.rs(88);
    final initial = Container(
      width: size,
      height: size,
      color: const Color(0xFFE8DFC8),
      alignment: Alignment.center,
      child: Text(
        peer.displayName.characters.first,
        style: TextStyle(
          fontSize: context.sp(30),
          fontWeight: FontWeight.w900,
          color: _accent,
        ),
      ),
    );
    final waiting = _phase == _Phase.waitingPeer;
    final connected = _phase == _Phase.connected;
    final badgeSize = context.rs(30);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            ClipOval(
              child: peer.profileImageUrl == null
                  ? initial
                  : AppNetworkImage(
                      peer.profileImageUrl!,
                      width: size,
                      height: size,
                      placeholderBuilder: (_) => initial,
                      errorBuilder: (_) => initial,
                    ),
            ),
            if (connected)
              Positioned(
                right: -4,
                bottom: -4,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.elasticOut,
                  builder: (context, t, child) =>
                      Transform.scale(scale: t, child: child),
                  child: Container(
                    width: badgeSize,
                    height: badgeSize,
                    decoration: BoxDecoration(
                      color: _accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: _paperColor, width: 3),
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      size: badgeSize * 0.62,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
        SizedBox(height: context.rs(18)),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Text(
            connected
                ? (_reMeet
                      ? '${peer.displayName}님을 다시 만났어요!'
                      : '${peer.displayName}님과 연결됐어요!')
                : waiting
                ? '${peer.displayName}님의 확인을 기다리고 있어요'
                : '${peer.displayName}님 맞나요?',
            key: ValueKey(_phase),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(18),
              fontWeight: FontWeight.w900,
              color: Colors.black87,
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          child: connected
              ? Padding(
                  padding: EdgeInsets.only(top: context.rs(8)),
                  child: Text(
                    '함께한 기록을 펼쳐볼게요',
                    style: TextStyle(
                      fontSize: context.sp(13),
                      color: Colors.black54,
                    ),
                  ),
                )
              : Padding(
                  padding: EdgeInsets.only(top: context.rs(24)),
                  child: waiting
                      ? const CircularProgressIndicator()
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            OutlinedButton(
                              onPressed: _reject,
                              child: const Text('아니에요'),
                            ),
                            SizedBox(width: context.rs(12)),
                            FilledButton(
                              onPressed: _confirm,
                              style: FilledButton.styleFrom(
                                backgroundColor: _accent,
                              ),
                              child: const Text('맞아요, 연결할게요'),
                            ),
                          ],
                        ),
                ),
        ),
      ],
    );
  }
}

/// 찾는 중 퍼져나가는 동심원.
class _PulsePainter extends CustomPainter {
  final double progress;
  final Color color;

  const _PulsePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    for (var i = 0; i < 2; i++) {
      final p = (progress + i / 2) % 1;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: (1 - p) * 0.5);
      canvas.drawCircle(center, maxRadius * (0.45 + 0.55 * p), paint);
    }
    canvas.drawCircle(
      center,
      maxRadius * 0.42,
      Paint()..color = color.withValues(alpha: 0.1),
    );
  }

  @override
  bool shouldRepaint(_PulsePainter oldDelegate) =>
      oldDelegate.progress != progress;
}
