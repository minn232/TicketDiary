import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/ticket_alignment_detector.dart';

/// 단일 채널(Y 평면) 합성 프레임을 만듭니다. [brightnessAt]이 각 픽셀의
/// 밝기(0~255)를 결정합니다. 실기기 카메라 없이 [LiveTicketAlignmentDetector]
/// 의 분석 파이프라인을 검증하는 용도입니다.
CameraImage buildFakeFrame({
  required int width,
  required int height,
  required int Function(int row, int col) brightnessAt,
}) {
  final bytes = Uint8List(width * height);
  for (var row = 0; row < height; row++) {
    for (var col = 0; col < width; col++) {
      bytes[row * width + col] = brightnessAt(row, col).clamp(0, 255);
    }
  }
  final data = CameraImageData(
    format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
    height: height,
    width: width,
    planes: [CameraImagePlane(bytes: bytes, bytesPerRow: width)],
  );
  return CameraImage.fromPlatformInterface(data);
}

CameraController buildFakeController() {
  return CameraController(
    const CameraDescription(
      name: 'test',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
    ResolutionPreset.low,
  );
}

const int kBg = 30; // 배경(박스 바깥) 밝기

/// 티켓 종이 밝기. 실제 티켓은 글자/그림이 있어 대비(표준편차)가
/// 있어야 minContrast 조건을 통과하므로, 균일한 값 대신 row%7 기준으로
/// 두 밝기를 섞습니다(어떤 샘플링 간격을 쓰든 7과 서로소가 아닌 간격이
/// 아니면 최소 한 주기 안에서 양쪽 값이 모두 섞입니다).
int paperBrightness(int row, int col) => row % 7 < 3 ? 120 : 200;

void main() {
  // 첫 프레임은 밝기 기준선(EMA)이 없어 항상 steady=false로 판정에서
  // 제외되므로, 같은 프레임을 최소 2번 넣어야(기준선 확보 + 안정성 확인)
  // 정렬로 인식됩니다.
  const width = 200;
  const height = 300;

  test('박스 전체가 채워지면 정렬로 인식된다', () async {
    final detector = LiveTicketAlignmentDetector(
      buildFakeController(),
      requiredStableFrames: 1,
    );

    final events = <bool>[];
    final sub = detector.alignmentStream.listen(events.add);

    // 배경(가장자리)만 어둡게, 나머지(중심 영역)는 티켓 종이 밝기로 채웁니다.
    final bgFrame = buildFakeFrame(
      width: width,
      height: height,
      brightnessAt: (row, col) {
        final isEdge = row < height * 0.1 ||
            row >= height * 0.9 ||
            col < width * 0.1 ||
            col >= width * 0.9;
        return isEdge ? kBg : paperBrightness(row, col);
      },
    );

    detector.debugProcessFrame(bgFrame);
    detector.debugProcessFrame(bgFrame);
    // alignmentStream은 broadcast StreamController라 add()가 비동기로
    // 전달되므로, 이벤트 루프를 한 번 돌려야 리스너가 값을 받습니다.
    await Future<void>.delayed(Duration.zero);

    expect(events, contains(true));
    await sub.cancel();
  });

  /// 스텁(입장티켓)이 뜯긴 티켓을 가정한 4가지 패턴(위/아래 행 제외,
  /// 왼쪽/오른쪽 열 제외 중 한쪽만 채워짐) 각각에서, 실제 센서의 행/열이
  /// 가이드 박스의 세로/가로 중 어느 쪽에 대응하든 정렬로 인식되는지
  /// 검증합니다.
  for (final pattern in [
    'topRowsFilled',
    'bottomRowsFilled',
    'leftColsFilled',
    'rightColsFilled',
  ]) {
    test('스텁 뜯긴 티켓 패턴($pattern)도 정렬로 인식된다', () async {
      final detector = LiveTicketAlignmentDetector(
        buildFakeController(),
        requiredStableFrames: 1,
      );

      final events = <bool>[];
      final sub = detector.alignmentStream.listen(events.add);

      bool isFilled(int row, int col) {
        // 가운데 영역(centerMarginFraction=0.2 기준 [0.2,0.8])의 대략
        // 70%만 채워지고 나머지는 비어있는 상황을 재현합니다.
        const stubRatio = 4.5 / 14.9;
        switch (pattern) {
          case 'topRowsFilled':
            return row < height * (0.2 + 0.6 * (1 - stubRatio));
          case 'bottomRowsFilled':
            return row >= height * (0.2 + 0.6 * stubRatio);
          case 'leftColsFilled':
            return col < width * (0.2 + 0.6 * (1 - stubRatio));
          case 'rightColsFilled':
            return col >= width * (0.2 + 0.6 * stubRatio);
          default:
            throw StateError('unknown pattern');
        }
      }

      final frame = buildFakeFrame(
        width: width,
        height: height,
        brightnessAt: (row, col) {
          final isEdge = row < height * 0.1 ||
              row >= height * 0.9 ||
              col < width * 0.1 ||
              col >= width * 0.9;
          if (isEdge) return kBg;
          return isFilled(row, col) ? paperBrightness(row, col) : kBg;
        },
      );

      detector.debugProcessFrame(frame);
      detector.debugProcessFrame(frame);
      await Future<void>.delayed(Duration.zero);

      expect(events, contains(true), reason: 'pattern=$pattern');
      await sub.cancel();
    });
  }

  test('아무것도 없으면(박스 안팎이 같은 배경) 정렬로 인식되지 않는다', () async {
    final detector = LiveTicketAlignmentDetector(
      buildFakeController(),
      requiredStableFrames: 1,
    );

    final events = <bool>[];
    final sub = detector.alignmentStream.listen(events.add);

    final frame = buildFakeFrame(
      width: width,
      height: height,
      brightnessAt: (row, col) => kBg, // 안팎 모두 같은 배경
    );

    detector.debugProcessFrame(frame);
    detector.debugProcessFrame(frame);
    detector.debugProcessFrame(frame);
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    await sub.cancel();
  });
}
