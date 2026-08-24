import 'dart:async';
import 'dart:math' show sqrt;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// 스캔 가이드 박스(6:14.9, 입장권 포함 티켓 전체 규격) 중 "입장티켓"이
/// 차지하는 세로 비율(아래쪽 4.5). 공연을 이미 본 뒤 추가하는 티켓은
/// 입장권 스텁이 뜯겨 있어 이 부분이 비어 있을 수 있으므로, 감지기와
/// 가이드 오버레이(UI) 양쪽이 같은 값을 공유합니다.
const double kTicketStubHeightRatio = 4.5 / 14.9;

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
/// 판단할 수 있는 신호를 프레임마다 계산해, 일정 프레임 이상 연속으로
/// 만족하면 "정렬됨"으로 판단하는 가벼운 휴리스틱입니다.
///
/// 1. **밝기**: 너무 어둡지(렌즈를 가림) 너무 밝지도(빛 반사) 않은지
/// 2. **대비(표준편차)**: 화면에 글자/그림 같은 디테일이 있는지
///    (빈 벽·손바닥처럼 대비가 거의 없는 장면을 배제하기 위함)
/// 3. **안정성**: 직전 프레임과 밝기 차이가 작은지(사용자가 카메라를
///    흔들지 않고 가만히 들고 있는지)
///
/// 예전엔 이 3가지를 프레임 **전체**에 대해 계산해서, 가이드 박스 밖에
/// 뭔가 안정적으로 잡혀 있어도(예: 카메라를 든 손, 책상 등) "정렬됨"으로
/// 오판하고 계속 촬영되는 문제가 있었습니다. 이제는 프레임 중심부(가이드
/// 박스가 항상 화면 가운데 대부분을 차지하도록 그려지므로, 안쪽 여백을
/// 뺀 중심 영역은 센서 회전값을 몰라도 그 위치와 대략 겹칩니다)만
/// 샘플링해서, 가이드 박스 바깥 상황은 정렬 판단에 영향을 주지 않습니다.
///
/// 4. **박스 채움(안-밖 대비)**: 여기에 더해, 가운데(가이드 박스 안쪽
///    근사) 영역과 프레임 가장자리(박스 바깥 근사) 영역의 평균 밝기가
///    충분히 달라야 합니다. 티켓(종이)이 실제로 박스를 채우면 안쪽은
///    종이 밝기, 바깥쪽은 배경(책상 등)이라 차이가 크지만, 박스에 아무
///    것도 없으면 안팎이 같은 배경이라 차이가 거의 없습니다 — 이 조건이
///    "박스에 티켓을 맞췄을 때만" 찍히게 하는 핵심 필터입니다.
///
/// 공연 전 티켓은 입장권 스텁이 붙어 있어 가이드 박스(6:14.9) 전체를
/// 채우지만, 공연을 다 본 뒤 추가하는 티켓은 스텁이 이미 뜯겨 있어 박스의
/// 한쪽 끝([kTicketStubHeightRatio]만큼)이 빈 채로 남습니다. 그래서 위
/// 1~4번 판정을 "박스 전체" 기준과 "스텁을 뺀 티켓 영역만" 기준으로 각각
/// 실행해서, 둘 중 하나만 만족해도 정렬로 인정합니다.
///
/// **주의**: 카메라 원본 프레임(raw sensor buffer)의 행(row)/열(col) 축이
/// 화면에 그려지는 가이드 박스의 세로/가로 축 중 정확히 어느 쪽에
/// 대응하는지(그리고 스텁이 시작 쪽/끝 쪽 중 어디에 놓이는지)는 기기의
/// 센서 장착 방향(Android `sensorOrientation` 등)에 따라 달라질 수 있고,
/// 이 프로젝트엔 실기기로 카메라를 켜서 검증할 방법이 없었습니다. 그래서
/// "위/아래/왼쪽/오른쪽 중 한쪽을 스텁 비율만큼 제외"하는 4가지 후보를
/// 모두 검사해서, 실제 대응 관계가 어느 쪽이든 정상 동작하도록 합니다.
class LiveTicketAlignmentDetector implements TicketAlignmentDetector {
  LiveTicketAlignmentDetector(
    this._controller, {
    this.requiredStableDuration = const Duration(seconds: 2),
    this.minBrightness = 75,
    this.maxBrightness = 235,
    this.minContrast = 26,
    this.maxFrameDelta = 10,
    this.centerMarginFraction = 0.2,
    this.outerBandFraction = 0.1,
    this.minCenterEdgeDelta = 14,
    this.smoothingFactor = 0.25,
  });

  final CameraController _controller;

  /// 정렬 판정을 내리기까지 연속으로 조건을 만족한 채 유지돼야 하는
  /// 시간. 프레임 수 대신 실제 경과 시간으로 재서, 기기별로 카메라
  /// 프레임 속도(fps)가 달라도 항상 같은 길이만큼 가만히 있어야
  /// 촬영됩니다. 티켓을 박스에 맞춘 채 이 시간만큼 들고 있어야만
  /// 촬영되고, 지나가는 장면이나 잠깐의 흔들림에는 반응하지 않습니다.
  final Duration requiredStableDuration;

  /// 티켓 종이가 정상 조명에서 갖는 밝기 하한. 어두운 책상/벽 등
  /// 티켓이 아닌 장면을 걸러냅니다.
  final double minBrightness;
  final double maxBrightness;
  final double minContrast;
  final double maxFrameDelta;

  /// 프레임의 가장자리에서 이 비율만큼(가로/세로 각각)을 제외한 중심
  /// 영역을 "가이드 박스 안쪽"으로 간주해 분석합니다.
  final double centerMarginFraction;

  /// 프레임 가장자리에서 이 비율 안쪽까지의 띠를 "가이드 박스 바깥"으로
  /// 간주해, 중심 영역과의 밝기 차이 계산에 씁니다.
  final double outerBandFraction;

  /// 중심(박스 안)과 가장자리(박스 밖) 평균 밝기가 최소 이만큼 달라야
  /// "티켓이 박스를 채웠다"로 인정합니다.
  final double minCenterEdgeDelta;

  /// 밝기 기준선을 갱신하는 지수이동평균(EMA) 계수. 값이 작을수록 기준선이
  /// 천천히 움직여, 카메라 자동노출의 프레임 단위 미세 흔들림에 덜 민감해집니다.
  final double smoothingFactor;

  final StreamController<bool> _output = StreamController<bool>.broadcast();
  final StreamController<void> _unsupported =
      StreamController<void>.broadcast();
  bool _busy = false;
  bool _emitted = false;

  /// 판정 후보 영역들: 박스 전체 1개 + "스텁 쪽 끝을 제외한 티켓 영역"
  /// 4가지(위/아래 행 제외, 왼쪽/오른쪽 열 제외 — 실제 센서 방향을 몰라
  /// 4가지를 모두 둠). 각 후보의 rowStart/rowEnd/colStart/colEnd는
  /// 박스 안쪽 범위([0,1])에 대한 비율입니다.
  static const List<({double rowStart, double rowEnd, double colStart, double colEnd})>
      _regionCandidates = [
    (rowStart: 0, rowEnd: 1, colStart: 0, colEnd: 1), // 박스 전체
    (rowStart: 0, rowEnd: 1 - kTicketStubHeightRatio, colStart: 0, colEnd: 1), // 아래쪽 행 제외
    (rowStart: kTicketStubHeightRatio, rowEnd: 1, colStart: 0, colEnd: 1), // 위쪽 행 제외
    (rowStart: 0, rowEnd: 1, colStart: 0, colEnd: 1 - kTicketStubHeightRatio), // 오른쪽 열 제외
    (rowStart: 0, rowEnd: 1, colStart: kTicketStubHeightRatio, colEnd: 1), // 왼쪽 열 제외
  ];

  /// 후보별 밝기 기준선(EMA)과, 그 후보가 조건을 계속 만족하기 시작한
  /// 시각(끊기면 다시 null로 리셋). 후보마다 독립적으로 추적해서, 그
  /// 후보가 실제로 "티켓으로 채워진" 쪽이면 정상 수렴해 정렬로 인정될
  /// 수 있습니다.
  final List<double?> _smoothBrightness =
      List<double?>.filled(_regionCandidates.length, null);
  final List<DateTime?> _stableSince =
      List<DateTime?>.filled(_regionCandidates.length, null);

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

  /// 테스트 전용: 실제 카메라 스트림/하드웨어 없이 프레임 하나를 직접
  /// 분석 파이프라인에 넣습니다. 이 프로젝트엔 실기기로 카메라를 켜서
  /// 검증할 방법이 없어서, 합성 프레임으로 정렬 판정 로직(특히
  /// [_regionCandidates] 4방향 후보)을 단위 테스트로 확인하는 용도입니다.
  @visibleForTesting
  void debugProcessFrame(CameraImage image) => _onFrame(image);

  void _onFrame(CameraImage image) {
    if (_busy || _emitted || _output.isClosed) return;
    _busy = true;
    try {
      final analysis = _analyze(image);

      final now = DateTime.now();
      var anyReady = false;
      for (var i = 0; i < _regionCandidates.length; i++) {
        final pass = _evaluateRegion(
          analysis.regions[i],
          outerBrightness: analysis.outerBrightness,
          hasOuter: analysis.hasOuter,
          baseline: _smoothBrightness[i],
          onBaseline: (v) => _smoothBrightness[i] = v,
        );
        if (!pass) {
          _stableSince[i] = null;
          continue;
        }
        final since = _stableSince[i] ??= now;
        if (now.difference(since) >= requiredStableDuration) anyReady = true;
      }

      if (anyReady && !_emitted) {
        _emitted = true;
        _output.add(true);
      }
    } finally {
      _busy = false;
    }
  }

  /// 중심 영역 통계 하나가 정렬 판정 4가지 조건(밝기/대비/안정성/안-밖
  /// 대비)을 모두 만족하는지 검사하고, 그 영역 전용 밝기 기준선(EMA)을
  /// 갱신합니다. 후보마다 독립된 기준선을 쓰므로, 그중 하나만 티켓으로
  /// 채워져도 그쪽 기준선은 정상 수렴해 정렬로 인정될 수 있습니다.
  bool _evaluateRegion(
    _RegionStats stats, {
    required double outerBrightness,
    required bool hasOuter,
    required double? baseline,
    required void Function(double) onBaseline,
  }) {
    final brightnessOk =
        stats.mean >= minBrightness && stats.mean <= maxBrightness;
    final contrastOk = stats.contrast >= minContrast;
    final fillsGuide = hasOuter &&
        (stats.mean - outerBrightness).abs() >= minCenterEdgeDelta;
    final steady = baseline == null
        ? false
        : (stats.mean - baseline).abs() <= maxFrameDelta;
    onBaseline(baseline == null
        ? stats.mean
        : baseline + (stats.mean - baseline) * smoothingFactor);
    return brightnessOk && contrastOk && steady && fillsGuide;
  }

  /// 프레임 가운데 영역([centerMarginFraction]로 가장자리를 제외한 부분)
  /// 안에서, [_regionCandidates] 각각의 평균 밝기·대비(표준편차)를
  /// 계산하고, 가장자리 띠([outerBandFraction])의 평균 밝기도 함께
  /// 계산합니다. 매 픽셀을 다 읽으면 비용이 커서 행/열 방향으로
  /// 듬성듬성 샘플링합니다.
  ///
  /// 행(row) 단위로 오프셋을 계산할 때 [CameraImagePlane.bytesPerRow]를
  /// 써야 합니다 — YUV 포맷은 정렬을 위해 한 행의 실제 바이트 폭이
  /// [CameraImage.width]보다 클 수 있어서, 이를 무시하고 1차원으로만
  /// 훑으면 행이 갈수록 어긋나 "가운데 영역"이 실제로는 다른 곳을 가리키게 됩니다.
  _FrameAnalysis _analyze(CameraImage image) {
    final plane = image.planes.first;
    final bytes = plane.bytes;
    // iOS 기본 포맷(bgra8888)은 픽셀당 4바이트(B,G,R,A) 인터리브,
    // Android 기본 포맷(yuv420/nv21)은 첫 플레인이 곧 휘도(Y) 값입니다.
    final isPacked = image.format.group == ImageFormatGroup.bgra8888;
    final pixelStride = isPacked ? 4 : 1;
    final bytesPerRow = plane.bytesPerRow;
    final width = image.width;
    final height = image.height;

    int luma(int row, int col) {
      final i = row * bytesPerRow + col * pixelStride;
      if (i + pixelStride > bytes.length) return -1;
      return isPacked
          ? ((bytes[i + 2] * 299 + bytes[i + 1] * 587 + bytes[i] * 114) ~/ 1000)
          : bytes[i];
    }

    final marginRows = (height * centerMarginFraction).round();
    final marginCols = (width * centerMarginFraction).round();
    final rowStart = marginRows;
    final rowEnd = height - marginRows;
    final colStart = marginCols;
    final colEnd = width - marginCols;
    if (rowEnd <= rowStart || colEnd <= colStart) {
      return _FrameAnalysis(
        regions: List<_RegionStats>.filled(
          _regionCandidates.length,
          _RegionStats.empty,
        ),
        outerBrightness: 0,
        hasOuter: false,
      );
    }

    // 가운데 영역 안에서 가로/세로 각각 약 50포인트씩만 샘플링합니다
    // (프레임마다 실행되므로 비용을 낮게 유지).
    const targetSamplesPerAxis = 50;
    final rowStep = ((rowEnd - rowStart) / targetSamplesPerAxis)
        .clamp(1, double.infinity)
        .round();
    final colStep = ((colEnd - colStart) / targetSamplesPerAxis)
        .clamp(1, double.infinity)
        .round();

    final regions = [
      for (final candidate in _regionCandidates)
        _sampleRegion(
          luma,
          rowStart: (rowStart + (rowEnd - rowStart) * candidate.rowStart)
              .round()
              .clamp(rowStart, rowEnd),
          rowEnd: (rowStart + (rowEnd - rowStart) * candidate.rowEnd)
              .round()
              .clamp(rowStart + 1, rowEnd),
          colStart: (colStart + (colEnd - colStart) * candidate.colStart)
              .round()
              .clamp(colStart, colEnd),
          colEnd: (colStart + (colEnd - colStart) * candidate.colEnd)
              .round()
              .clamp(colStart + 1, colEnd),
          rowStep: rowStep,
          colStep: colStep,
        ),
    ];

    // 가장자리 띠(박스 바깥 근사): 상/하 띠는 전체 폭을, 좌/우 띠는 상/하
    // 띠와 겹치지 않는 나머지 높이를 훑습니다. 모든 후보 판정이 이 바깥
    // 띠를 공유합니다 — 어느 후보든 "박스 바깥은 배경"이라는 전제가
    // 같기 때문입니다.
    final outerRows = (height * outerBandFraction).round();
    final outerCols = (width * outerBandFraction).round();
    int outerSum = 0;
    int outerCount = 0;

    void sampleOuter(int r0, int r1, int c0, int c1) {
      if (r1 <= r0 || c1 <= c0) return;
      for (int row = r0; row < r1; row += rowStep) {
        for (int col = c0; col < c1; col += colStep) {
          final value = luma(row, col);
          if (value < 0) continue;
          outerSum += value;
          outerCount++;
        }
      }
    }

    sampleOuter(0, outerRows, 0, width); // 위쪽 띠
    sampleOuter(height - outerRows, height, 0, width); // 아래쪽 띠
    sampleOuter(outerRows, height - outerRows, 0, outerCols); // 왼쪽 띠
    sampleOuter(outerRows, height - outerRows, width - outerCols, width); // 오른쪽 띠

    return _FrameAnalysis(
      regions: regions,
      outerBrightness: outerCount > 0 ? outerSum / outerCount : 0,
      hasOuter: outerCount > 0,
    );
  }

  /// 주어진 행/열 범위의 평균 밝기(mean)와 대비(표준편차, contrast)를
  /// 계산합니다. [rowStep]/[colStep]은 호출부가 정한 샘플링 간격을
  /// 그대로 씁니다.
  _RegionStats _sampleRegion(
    int Function(int row, int col) luma, {
    required int rowStart,
    required int rowEnd,
    required int colStart,
    required int colEnd,
    required int rowStep,
    required int colStep,
  }) {
    int sum = 0;
    int sumSq = 0;
    int count = 0;
    for (int row = rowStart; row < rowEnd; row += rowStep) {
      for (int col = colStart; col < colEnd; col += colStep) {
        final value = luma(row, col);
        if (value < 0) continue;
        sum += value;
        sumSq += value * value;
        count++;
      }
    }
    if (count == 0) return _RegionStats.empty;
    final mean = sum / count;
    final variance = (sumSq / count) - (mean * mean);
    return _RegionStats(mean: mean, contrast: variance > 0 ? sqrt(variance) : 0.0);
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

/// 후보 영역 하나(박스 전체 또는 스텁 쪽 끝을 제외한 티켓 영역)의 평균
/// 밝기·대비.
class _RegionStats {
  final double mean;
  final double contrast;

  const _RegionStats({required this.mean, required this.contrast});

  static const empty = _RegionStats(mean: 0, contrast: 0);
}

/// 한 프레임 분석 결과: [LiveTicketAlignmentDetector._regionCandidates]
/// 순서와 1:1 대응하는 중심 영역 통계들, 그리고 모든 후보가 공유하는
/// 가장자리(바깥) 밝기.
class _FrameAnalysis {
  final List<_RegionStats> regions;

  /// 프레임 가장자리 띠(가이드 박스 바깥 근사)의 평균 밝기.
  final double outerBrightness;

  /// 가장자리 띠에서 유효 샘플을 얻었는지(못 얻었으면 안-밖 대비 판단 불가).
  final bool hasOuter;

  const _FrameAnalysis({
    required this.regions,
    required this.outerBrightness,
    required this.hasOuter,
  });
}
