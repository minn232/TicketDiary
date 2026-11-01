import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../screen/meeting_card_screen.dart';
import '../screen/nearby_tap_screen.dart';
import '../services/app_settings_store.dart';
import '../services/shake_detector.dart';
import 'responsive_text.dart';

// [백엔드 수정]
// 다이어리 화면에서 폰을 흔들면 맞대기 화면을 열고, 만나면 일회용 카드를 띄움.
// 설정이 켜져 있고 앱이 보이는 동안만 센서를 듣고, 다이어리 위에 다른 화면이 떠 있으면 무시.
class ShakeToMeet extends StatefulWidget {
  final Widget child;
  // 티켓 추가 펼침·전환 연출 중처럼 다이어리가 바쁠 땐 false
  final bool enabled;

  const ShakeToMeet({super.key, required this.child, this.enabled = true});

  @override
  State<ShakeToMeet> createState() => _ShakeToMeetState();
}

class _ShakeToMeetState extends State<ShakeToMeet> with WidgetsBindingObserver {
  final _detector = ShakeDetector();
  final _clock = Stopwatch()..start();
  StreamSubscription<Object>? _sub;
  bool _resumed = true;
  // 맞대기 화면이 열린 동안은 센서를 끔(맞대는 동작이 다시 흔들기로 잡히지 않게)
  bool _opening = false;

  // 맞대기는 안드로이드·iOS만
  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppSettingsStore.instance.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant ShakeToMeet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppSettingsStore.instance.removeListener(_sync);
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final listen =
        _supported &&
        widget.enabled &&
        _resumed &&
        !_opening &&
        AppSettingsStore.instance.shakeToMeet;
    if (listen && _sub == null) {
      _detector.reset();
      _sub = userAccelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen((e) => _onAccel(e.x, e.y, e.z), onError: _fallbackToGravity);
    } else if (!listen && _sub != null) {
      _sub?.cancel();
      _sub = null;
    }
  }

  // 선형가속도 센서가 없는 기기(A15)는 일반 가속도에서 중력을 저역통과로 추정해 뺌
  void _fallbackToGravity(Object _) {
    _sub?.cancel();
    var gravity = [0.0, 0.0, 9.8];
    _sub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen((e) {
          final raw = [e.x, e.y, e.z];
          gravity = [
            for (var i = 0; i < 3; i++) gravity[i] * 0.9 + raw[i] * 0.1,
          ];
          _onAccel(
            raw[0] - gravity[0],
            raw[1] - gravity[1],
            raw[2] - gravity[2],
          );
        }, onError: (Object _) {});
  }

  void _onAccel(double x, double y, double z) {
    if (!_detector.add(x, y, z, _clock.elapsed)) return;
    // 다이어리 위에 다른 화면(오버레이·시트·다른 탭)이 떠 있으면 무시
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    unawaited(_open());
  }

  Future<void> _open() async {
    _opening = true;
    _sync();
    HapticFeedback.mediumImpact();
    final frameScale =
        DiaryFrameScale.maybeOf(context) ?? diaryScaleFromMediaQuery(context);
    try {
      await NearbyTapScreen.show(
        context,
        frameScale: frameScale,
        // 물방울이 화면 아래에 닿을 즈음 - 그 자리에서 카드 패널이 차오름
        onConnected: (peer, card) {
          if (!mounted) return;
          unawaited(
            MeetingCardScreen.show(
              context,
              frameScale: frameScale,
              peer: peer,
              card: card,
            ),
          );
        },
      );
    } finally {
      _opening = false;
      if (mounted) _sync();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
