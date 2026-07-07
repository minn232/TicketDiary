import 'dart:async';

/// 티켓이 스캔 가이드 박스에 잘 맞춰졌는지 판단하는 감지기 인터페이스.
///
/// 실제 기기에서는 카메라 프레임을 분석(외곽선/모서리 검출 등)해
/// [alignmentStream]으로 정렬 여부를 흘려보내는 구현체로 교체할 수 있습니다.
abstract class TicketAlignmentDetector {
  /// 정렬 상태가 바뀔 때마다 true/false를 흘려보내는 스트림.
  Stream<bool> get alignmentStream;

  /// 감지를 시작합니다.
  void start();

  void dispose();
}

/// 실제 정렬 감지 로직이 준비되기 전까지 사용하는 시뮬레이션 구현체.
/// 일정 시간 뒤 "정렬됨" 신호를 한 번 보내 자동 촬영을 트리거합니다.
class SimulatedTicketAlignmentDetector implements TicketAlignmentDetector {
  SimulatedTicketAlignmentDetector({
    this.alignDelay = const Duration(milliseconds: 1400),
  });

  final Duration alignDelay;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  Timer? _timer;

  @override
  Stream<bool> get alignmentStream => _controller.stream;

  @override
  void start() {
    _timer?.cancel();
    _timer = Timer(alignDelay, () {
      if (!_controller.isClosed) _controller.add(true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.close();
  }
}
