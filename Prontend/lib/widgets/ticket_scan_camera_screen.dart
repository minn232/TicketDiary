import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../models/ticket_scan.dart';
import '../services/api_client.dart';
import '../services/ticket_scan_service.dart';
import 'ticket_alignment_detector.dart';

enum _ScanStage { positioning, aligned, capturing }

/// 화면 오른쪽 아래 "임시 스캔" 버튼을 눌렀을 때 [TicketScanCameraScreen]이
/// 반환하는 값. 카메라 촬영이나 백엔드 OCR 호출을 전혀 거치지 않고, 호출부
/// (다이어리 화면)가 테스트용 더미 티켓을 바로 추가하도록 신호만 보냅니다.
class DebugFakeScanRequested {
  const DebugFakeScanRequested();
}

/// 신분증 스캔 UI처럼, 가이드 박스에 티켓을 맞추면
/// 자동으로 정렬을 인식(초록 테두리)하고 촬영까지 이어지는 카메라 화면.
///
/// 정렬 판단은 [TicketAlignmentDetector]에, 촬영된 사진의 OCR 추출 + 공연
/// 매칭은 [TicketScanService](백엔드 `POST /concerts/scan`)에 위임합니다.
/// 성공 시 [Navigator.pop]으로 [TicketScanResponse]를, 디버그 버튼으로
/// 종료하면 [DebugFakeScanRequested]를 반환합니다.
class TicketScanCameraScreen extends StatefulWidget {
  TicketScanCameraScreen({
    super.key,
    TicketScanService? scanService,
    TicketAlignmentDetector Function(CameraController controller)?
    detectorFactory,
  })  : scanService = scanService ?? BackendTicketScanService(),
        detectorFactory = detectorFactory ?? LiveTicketAlignmentDetector.new;

  final TicketScanService scanService;
  final TicketAlignmentDetector Function(CameraController controller)
  detectorFactory;

  @override
  State<TicketScanCameraScreen> createState() => _TicketScanCameraScreenState();
}

class _TicketScanCameraScreenState extends State<TicketScanCameraScreen> {
  CameraController? _controller;
  TicketAlignmentDetector? _detector;
  StreamSubscription<bool>? _alignSub;
  StreamSubscription<void>? _unsupportedSub;
  _ScanStage _stage = _ScanStage.positioning;
  String? _errorMessage;

  /// true면 이 플랫폼/기기가 실시간 프레임 스트리밍을 지원하지 않아(예:
  /// Flutter 웹) 자동 정렬 인식이 아예 동작할 수 없다는 뜻입니다. 이 경우
  /// 가이드 박스가 절대 초록색으로 바뀌지 않으므로, 대신 수동 촬영 버튼을
  /// 보여줍니다.
  bool _autoAlignUnsupported = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() => _errorMessage = '사용 가능한 카메라를 찾을 수 없습니다.');
        return;
      }
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      _startAlignmentDetection();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = '카메라를 여는 중 오류가 발생했습니다.');
    }
  }

  void _startAlignmentDetection() {
    final controller = _controller;
    if (controller == null) return;
    final detector = widget.detectorFactory(controller);
    _detector = detector;
    _alignSub = detector.alignmentStream.listen((aligned) {
      if (aligned && _stage == _ScanStage.positioning) {
        _onAligned();
      }
    });
    _unsupportedSub = detector.unsupportedStream.listen((_) {
      if (!mounted) return;
      setState(() => _autoAlignUnsupported = true);
    });
    detector.start();
  }

  Future<void> _onAligned() async {
    if (!mounted) return;
    setState(() => _stage = _ScanStage.aligned);
    // 초록 테두리를 잠깐 보여준 뒤 자동 촬영
    await Future.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    await _captureAndExtract();
  }

  Future<void> _captureAndExtract() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    // 정렬 인식이 카메라 이미지 스트림을 쓰고 있으면, 스트리밍 중에는
    // takePicture()가 실패하거나 화질이 떨어질 수 있는 기기가 있어 먼저 멈춥니다.
    _alignSub?.cancel();
    _unsupportedSub?.cancel();
    _detector?.dispose();
    _detector = null;

    setState(() => _stage = _ScanStage.capturing);
    try {
      final photo = await controller.takePicture();
      final result = await widget.scanService.scanTicket(photo);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      // 백엔드가 준 구체적인 실패 사유(이미지 인식 실패/용량 초과/Vision API
      // 오류 등)를 그대로 보여줍니다.
      if (!mounted) return;
      setState(() {
        _stage = _ScanStage.positioning;
        _errorMessage = e.message;
      });
      await _rearmAlignmentDetection();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _ScanStage.positioning;
        _errorMessage = '스캔 중 오류가 발생했습니다. 다시 시도해주세요.';
      });
      await _rearmAlignmentDetection();
    }
  }

  /// 실패 직후 바로 정렬 인식을 다시 켜면, 카메라 앞 장면이 그대로인 채로
  /// 곧장 다시 "정렬됨"으로 판정돼 촬영→실패→재촬영이 끊임없이 반복될 수
  /// 있습니다(연결 실패처럼 정렬과 무관한 오류일 때 특히 심함). 잠깐
  /// 멈춰서 사용자가 오류 문구를 보고 티켓을 다시 위치시킬 시간을 줍니다.
  Future<void> _rearmAlignmentDetection() async {
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    _startAlignmentDetection();
  }

  /// 카메라 촬영도, 백엔드 OCR 호출도 하지 않고 [DebugFakeScanRequested]를
  /// 반환해 즉시 화면을 닫는 테스트 전용 버튼 핸들러. 실제 기기/백엔드 없이
  /// UI 흐름(다이어리에 티켓이 추가되는 모습)만 확인하고 싶을 때 씁니다.
  void _debugAddFakeTicket() {
    if (_stage == _ScanStage.capturing) return;
    Navigator.of(context).pop(const DebugFakeScanRequested());
  }

  @override
  void dispose() {
    _alignSub?.cancel();
    _unsupportedSub?.cancel();
    _detector?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            CameraPreview(controller)
          else
            const Center(child: CircularProgressIndicator(color: Colors.white)),

          if (ready)
            _ScanGuideOverlay(
              stage: _stage,
              autoAlignUnsupported: _autoAlignUnsupported,
            ),

          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),

          if (_errorMessage != null)
            Positioned(
              bottom: 48,
              left: 24,
              right: 24,
              child: Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
              ),
            ),

          // 자동 정렬 인식을 아예 쓸 수 없는 환경(예: Flutter 웹)에서는
          // 가이드 박스가 절대 초록색으로 안 바뀌므로, 수동으로 실제
          // 촬영·스캔을 진행할 수 있는 버튼을 보여줍니다.
          if (_autoAlignUnsupported && _stage == _ScanStage.positioning)
            Positioned(
              bottom: 24,
              left: 16,
              child: FloatingActionButton.extended(
                heroTag: 'manual_capture',
                onPressed: _captureAndExtract,
                backgroundColor: const Color(0xFF38BDF8),
                icon: const Icon(Icons.camera_alt),
                label: const Text('지금 촬영하기'),
              ),
            ),

          // 개발용 임시 버튼: 카메라/백엔드 없이 테스트용 더미 티켓만 추가
          Positioned(
            bottom: 24,
            right: 16,
            child: FloatingActionButton.extended(
              heroTag: 'debug_force_scan',
              onPressed: _debugAddFakeTicket,
              backgroundColor: Colors.grey,
              label: const Text('임시 스캔'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanGuideOverlay extends StatelessWidget {
  const _ScanGuideOverlay({
    required this.stage,
    this.autoAlignUnsupported = false,
  });

  final _ScanStage stage;

  /// true면 이 환경에서는 자동 정렬 인식이 동작하지 않는다는 안내로 문구를 바꿉니다.
  final bool autoAlignUnsupported;

  String get _hintText {
    if (stage == _ScanStage.positioning && autoAlignUnsupported) {
      return '이 환경에서는 자동 인식이 지원되지 않아요.\n"지금 촬영하기" 버튼을 눌러주세요.';
    }
    return switch (stage) {
      _ScanStage.positioning => '티켓을 사각형 안에 맞춰주세요',
      _ScanStage.aligned => '인식 완료!',
      _ScanStage.capturing => '스캔 중...',
    };
  }

  Color get _borderColor => switch (stage) {
        _ScanStage.positioning => Colors.white70,
        _ScanStage.aligned || _ScanStage.capturing => const Color(0xFF38BDF8),
      };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 높이는 기존 기준(화면 폭의 86%에 14.8:6 비율)을 그대로 유지하고,
        // 가로 폭만 12:6 비율에 맞춰 줄입니다.
        final guideHeight = constraints.maxWidth * 0.86 * 6 / 14.8;
        final guideWidth = guideHeight * 12 / 6; // 12:6 비율
        final guideRect = Rect.fromCenter(
          center: Offset(constraints.maxWidth / 2, constraints.maxHeight / 2 - 30),
          width: guideWidth,
          height: guideHeight,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            // 가이드 박스 바깥만 살짝 어둡게(블러 없이, 안쪽은 카메라 화면 그대로)
            ClipPath(
              clipper: _OutsideGuideClipper(guideRect: guideRect, radius: 0),
              child: Container(color: Colors.black.withValues(alpha: 0.35)),
            ),

            // 가이드 박스 테두리(정렬되면 초록색으로 전환)
            Positioned.fromRect(
              rect: guideRect.inflate(2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                decoration: BoxDecoration(
                  border: Border.all(color: _borderColor, width: 3),
                  boxShadow: stage == _ScanStage.positioning
                      ? null
                      : [
                          BoxShadow(
                            color: _borderColor.withValues(alpha: 0.6),
                            blurRadius: 16,
                            spreadRadius: 1,
                          ),
                        ],
                ),
              ),
            ),

            Positioned(
              top: guideRect.bottom + 24,
              left: 24,
              right: 24,
              child: Text(
                _hintText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 가이드 박스(구멍)를 제외한 나머지 영역만 잘라내는 클리퍼.
class _OutsideGuideClipper extends CustomClipper<Path> {
  _OutsideGuideClipper({required this.guideRect, required this.radius});

  final Rect guideRect;
  final double radius;

  @override
  Path getClip(Size size) {
    final full = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final hole = Path()..addRRect(RRect.fromRectAndRadius(guideRect, Radius.circular(radius)));
    return Path.combine(PathOperation.difference, full, hole);
  }

  @override
  bool shouldReclip(covariant _OutsideGuideClipper oldClipper) {
    return oldClipper.guideRect != guideRect || oldClipper.radius != radius;
  }
}
