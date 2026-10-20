import 'dart:async';

import 'package:flutter/widgets.dart';

// [백엔드 수정]
// 전역 오프라인 신호 신규 - connectivity_plus 없이 [ApiClient] 요청 성패로
// 판단(서버 응답 자체를 못 받으면 오프라인, 4xx/5xx는 온라인으로 취급).
// 오프라인이 되면 다른 요청이 없어도 풀릴 수 있게 주기적으로/앱 복귀 시 [probe]로 재확인.
class ConnectivityStatus with WidgetsBindingObserver {
  ConnectivityStatus._() {
    isOffline.addListener(_onChanged);
  }
  static final ConnectivityStatus instance = ConnectivityStatus._();

  static const _probeInterval = Duration(seconds: 10);

  final ValueNotifier<bool> isOffline = ValueNotifier(false);

  /// 서버에 가벼운 요청을 한 번 보내는 함수([AuthService]가 등록). 성공/실패에 따라
  /// [ApiClient]가 [isOffline]을 갱신하므로 여기서는 결과를 보지 않습니다.
  Future<void> Function()? probe;

  Timer? _probeTimer;
  bool _observing = false;

  void _onChanged() {
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
    _probeTimer?.cancel();
    _probeTimer = isOffline.value
        ? Timer.periodic(_probeInterval, (_) => _runProbe())
        : null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && isOffline.value) _runProbe();
  }

  void _runProbe() {
    final run = probe;
    if (run == null) return;
    unawaited(run().catchError((_) {}));
  }
}
