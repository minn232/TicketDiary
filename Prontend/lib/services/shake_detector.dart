import 'dart:math' as math;

// [백엔드 수정]
// 폰 흔들기 판정 - 중력을 뺀 가속도(m/s²)를 넣으면 흔들기로 볼 때 true.
// 짧은 시간 안에 방향이 바뀌는 큰 흔들림이 여러 번 있어야 인정(맞대다 부딪히거나 내려놓는 한 번 튐은 무시).
class ShakeDetector {
  ShakeDetector({
    this.threshold = 10,
    this.requiredPeaks = 3,
    this.window = const Duration(milliseconds: 800),
    this.cooldown = const Duration(seconds: 2),
  });

  final double threshold;
  final int requiredPeaks;
  final Duration window;
  final Duration cooldown;

  // 방향이 바뀌어도 이 간격 안이면 셈하지 않음 - 책상에 세게 놓으면 0.1초 안에 위아래로 여러 번 튐
  static const _minGap = Duration(milliseconds: 100);

  final List<Duration> _peaks = [];
  int _lastSign = 0;
  Duration? _lastPeakAt;
  Duration? _firedAt;

  /// [at]은 단조 증가하는 시각(센서 이벤트 시각 등).
  bool add(double x, double y, double z, Duration at) {
    if (_firedAt != null && at - _firedAt! < cooldown) return false;
    if (math.sqrt(x * x + y * y + z * z) < threshold) return false;

    // 가장 크게 움직인 축의 방향
    final ax = x.abs(), ay = y.abs(), az = z.abs();
    final main = ax >= ay && ax >= az ? x : (ay >= az ? y : z);
    final sign = main >= 0 ? 1 : -1;

    // 방향이 바뀔 때만 셈 - 같은 방향은 한 번 휘두르는 중이거나 한쪽으로 툭툭 치는 것.
    // (예전엔 같은 방향이 이어지면 처음부터 다시 셌는데, 세게 흔들면 한 번 휘두르는 동안 기준을 넘는
    // 표본이 길게 이어져 계속 초기화돼 10회 중 3~4회를 놓쳤음 - 11/2 노트9 실측)
    if (sign == _lastSign) return false;
    final last = _lastPeakAt;
    if (last != null && at - last < _minGap) return false;
    _lastSign = sign;
    _lastPeakAt = at;
    _peaks
      ..add(at)
      ..removeWhere((t) => at - t > window);
    if (_peaks.length < requiredPeaks) return false;

    reset();
    _firedAt = at;
    return true;
  }

  void reset() {
    _peaks.clear();
    _lastSign = 0;
    _lastPeakAt = null;
  }
}
