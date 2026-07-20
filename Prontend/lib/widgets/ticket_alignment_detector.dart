import 'dart:async';
import 'dart:math' show sqrt;

import 'package:camera/camera.dart';

/// 티켓이 스캔 가이드 박스에 잘 맞춰졌는지 판단하는 감지기 인터페이스.
abstract class TicketAlignmentDetector {
  /// 정렬 상태가 바뀔 때마다 true/false를 흘려보내는 스트림.
  Stream<bool> get alignmentStream;

  /// 이 플랫폼/기기에서 실시간 프레임 스트리밍 자체를 지원하지 않아 자동
  /// 정렬 인식을 아예 쓸 수 없을 때 한 번 신호를 보내는 스트림.
  /// (예: Flutter 웹은 `camera` 패키지가 이미지 스트리밍을 구현하지 않음 —
  /// `startImageStream()`이 즉시 `UnimplementedError`를 던짐)
  Stream<void> get unsupportedStream;

  /// 감지를 시작합니다.
  void start();

  void dispose();
}

/// 개발/테스트용 시뮬레이션 구현체. 카메라 프레임은 전혀 보지 않고,
/// 일정 시간 뒤 "정렬됨" 신호를 한 번 보내 자동 촬영을 트리거합니다.
class SimulatedTicketAlignmentDetector implements TicketAlignmentDetector {
  SimulatedTicketAlignmentDetector({
    this.alignDelay = const Duration(milliseconds: 1400),
  });

  final Duration alignDelay;
  final StreamController<bool> _controller =
      StreamController<bool>.broadcast();
  final StreamController<void> _unsupported =
      StreamController<void>.broadcast();
  Timer? _timer;

  @override
  Stream<bool> get alignmentStream => _controller.stream;

  @override
  Stream<void> get unsupportedStream => _unsupported.stream;

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
    _unsupported.close();
  }
}

/// 실제 카메라 프레임을 분석해 "티켓이 화면에 안정적으로 잡혔는지"를
/// 판단하는 구현체.
///
/// **한계**: 티켓의 사각형 모서리를 찾아 원근/기울기까지 보정하는 진짜
/// "문서 스캐너" 수준의 정렬 인식은 아닙니다 — 그러려면 ML Kit(Google)이나
/// OpenCV 같은 별도 이미지 처리 라이브러리(윤곽선/사각형 검출)가 필요하고,
/// 이 프로젝트엔 아직 그런 의존성이 없습니다.
///
/// 대신 새 패키지 추가 없이 `camera` 패키지의 실시간 프레임 스트림만으로
/// 판단할 수 있는 3가지 신호를 프레임마다 계산해, 일정 프레임 이상 연속으로
/// 만족하면 "정렬됨"으로 판단하는 가벼운 휴리스틱입니다.
///
/// 1. **밝기**: 너무 어둡지(렌즈를 가림) 너무 밝지도(빛 반사) 않은지
/// 2. **대비(표준편차)**: 화면에 글자/그림 같은 디테일이 있는지
///    (빈 벽·손바닥처럼 대비가 거의 없는 장면을 배제하기 위함)
/// 3. **안정성**: 직전 프레임과 밝기 차이가 작은지(사용자가 카메라를
///    흔들지 않고 가만히 들고 있는지)
///
/// 즉 "티켓처럼 디테일이 있는 무언가를, 밝은 곳에서, 흔들지 않고 들고
/// 있다"를 근사하는 것이지 "그 사각형이 가이드 박스 안에 딱 들어왔다"를
/// 보는 게 아닙니다. 실기기에서 임계값(아래 필드들) 튜닝이 필요할 수
/// 있습니다.
class LiveTicketAlignmentDetector implements TicketAlignmentDetector {
  LiveTicketAlignmentDetector(
    this._controller, {
    this.requiredStableFrames = 8,
    this.minBrightness = 35,
    this.maxBrightness = 235,
    this.minContrast = 12,
    this.maxFrameDelta = 10,
    this.sampleStride = 31, // 규칙적인 샘플링 무늬(모아레)를 피하려 소수 사용
    this.smoothingFactor = 0.25,
  });

  final CameraController _controller;

  /// 정렬 판정을 내리기까지 연속으로 조건을 만족해야 하는 프레임 수.
  final int requiredStableFrames;
  final double minBrightness;
  final double maxBrightness;
  final double minContrast;
  final double maxFrameDelta;
  final int sampleStride;

  /// 밝기 기준선을 갱신하는 지수이동평균(EMA) 계수. 값이 작을수록 기준선이
  /// 천천히 움직여, 카메라 자동노출의 프레임 단위 미세 흔들림에 덜 민감해집니다.
  final double smoothingFactor;

  final StreamController<bool> _output = StreamController<bool>.broadcast();
  final StreamController<void> _unsupported =
      StreamController<void>.broadcast();
  bool _busy = false;
  bool _emitted = false;
  double? _smoothBrightness;
  int _stableCount = 0;

  @override
  Stream<bool> get alignmentStream => _output.stream;

  @override
  Stream<void> get unsupportedStream => _unsupported.stream;

  @override
  void start() {
    if (!_controller.value.isInitialized) return;
    unawaited(
      _controller.startImageStream(_onFrame).catchError((Object _) {
        // 이미지 스트리밍을 지원하지 않는 기기/브라우저(예: Flutter 웹은
        // startImageStream() 자체가 UnimplementedError를 던짐): 자동 정렬
        // 인식을 아예 쓸 수 없다는 신호를 보내, 화면이 수동 촬영으로
        // 안내하도록 합니다.
        if (!_unsupported.isClosed) _unsupported.add(null);
      }),
    );
  }

  void _onFrame(CameraImage image) {
    if (_busy || _emitted || _output.isClosed) return;
    _busy = true;
    try {
      final stats = _analyze(image);
      final brightnessOk =
          stats.brightness >= minBrightness && stats.brightness <= maxBrightness;
      final contrastOk = stats.contrast >= minContrast;

      // 바로 직전 프레임과 비교하면 카메라 자동노출의 프레임 단위 노이즈에도
      // 흔들림으로 오판하기 쉬우므로, 천천히 따라오는 이동평균 기준선과
      // 비교합니다(진짜 손떨림/움직임은 몇 프레임 안에 기준선도 같이 밀어내
      // 여전히 잡아냅니다).
      final baseline = _smoothBrightness;
      final steady = baseline == null
          ? false
          : (stats.brightness - baseline).abs() <= maxFrameDelta;
      _smoothBrightness = baseline == null
          ? stats.brightness
          : baseline + (stats.brightness - baseline) * smoothingFactor;

      _stableCount = (brightnessOk && contrastOk && steady) ? _stableCount + 1 : 0;

      if (_stableCount >= requiredStableFrames && !_emitted) {
        _emitted = true;
        _output.add(true);
      }
    } finally {
      _busy = false;
    }
  }

  /// 프레임에서 평균 밝기(brightness)와 대비(표준편차, contrast)를 계산합니다.
  /// 매 픽셀을 다 읽으면 비용이 커서 [sampleStride] 간격으로 듬성듬성 샘플링합니다.
  _FrameStats _analyze(CameraImage image) {
    final plane = image.planes.first;
    final bytes = plane.bytes;
    // iOS 기본 포맷(bgra8888)은 픽셀당 4바이트(B,G,R,A) 인터리브,
    // Android 기본 포맷(yuv420/nv21)은 첫 플레인이 곧 휘도(Y) 값입니다.
    final isPacked = image.format.group == ImageFormatGroup.bgra8888;
    final pixelStride = isPacked ? 4 : 1;
    final step = pixelStride * sampleStride;

    int sum = 0;
    int sumSq = 0;
    int count = 0;

    for (int i = 0; i + pixelStride <= bytes.length; i += step) {
      final int luma = isPacked
          ? ((bytes[i + 2] * 299 + bytes[i + 1] * 587 + bytes[i] * 114) ~/ 1000)
          : bytes[i];
      sum += luma;
      sumSq += luma * luma;
      count++;
    }

    if (count == 0) return const _FrameStats(brightness: 0, contrast: 0);

    final mean = sum / count;
    final variance = (sumSq / count) - (mean * mean);
    return _FrameStats(brightness: mean, contrast: variance > 0 ? sqrt(variance) : 0.0);
  }

  @override
  void dispose() {
    if (_controller.value.isStreamingImages) {
      unawaited(_controller.stopImageStream());
    }
    if (!_output.isClosed) _output.close();
    if (!_unsupported.isClosed) _unsupported.close();
  }
}

class _FrameStats {
  final double brightness;
  final double contrast;
  const _FrameStats({required this.brightness, required this.contrast});
}
