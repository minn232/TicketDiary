import 'dart:async';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../models/ticket_info.dart';
import '../services/ticket_ocr_service.dart';
import 'ticket_alignment_detector.dart';

enum _ScanStage { positioning, aligned, capturing }

/// 신분증 스캔 UI처럼, 가이드 박스에 티켓을 맞추면
/// 자동으로 정렬을 인식(초록 테두리)하고 촬영까지 이어지는 카메라 화면.
///
/// 정렬 판단은 [TicketAlignmentDetector]에, 정보 추출은 [TicketOcrService]에
/// 위임하므로, 실제 정렬 감지/OCR이 준비되면 각각 구현체만 교체하면 됩니다.
/// 성공 시 [Navigator.pop]으로 [TicketInfo]를 반환합니다.
class TicketScanCameraScreen extends StatefulWidget {
  TicketScanCameraScreen({
    super.key,
    TicketOcrService? ocrService,
    TicketAlignmentDetector Function()? detectorFactory,
  })  : ocrService = ocrService ?? const MockTicketOcrService(),
        detectorFactory = detectorFactory ?? SimulatedTicketAlignmentDetector.new;

  final TicketOcrService ocrService;
  final TicketAlignmentDetector Function() detectorFactory;

  @override
  State<TicketScanCameraScreen> createState() => _TicketScanCameraScreenState();
}

class _TicketScanCameraScreenState extends State<TicketScanCameraScreen> {
  CameraController? _controller;
  TicketAlignmentDetector? _detector;
  StreamSubscription<bool>? _alignSub;
  _ScanStage _stage = _ScanStage.positioning;
  String? _errorMessage;

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
    final detector = widget.detectorFactory();
    _detector = detector;
    _alignSub = detector.alignmentStream.listen((aligned) {
      if (aligned && _stage == _ScanStage.positioning) {
        _onAligned();
      }
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

    setState(() => _stage = _ScanStage.capturing);
    try {
      final photo = await controller.takePicture();
      final info = await widget.ocrService.extractTicketInfo(photo);
      if (!mounted) return;
      Navigator.of(context).pop(info);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _ScanStage.positioning;
        _errorMessage = '스캔 중 오류가 발생했습니다. 다시 시도해주세요.';
      });
      _startAlignmentDetection();
    }
  }

  /// 카메라/정렬 인식이 없는 개발 환경에서 테스트할 수 있도록,
  /// 실제 촬영 없이 바로 임시 스캔 결과를 반환하는 디버그용 버튼 핸들러.
  Future<void> _debugForceScan() async {
    if (_stage == _ScanStage.capturing) return;
    setState(() => _stage = _ScanStage.capturing);
    final info = await widget.ocrService.extractTicketInfo(XFile(''));
    if (!mounted) return;
    Navigator.of(context).pop(info);
  }

  @override
  void dispose() {
    _alignSub?.cancel();
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

          if (ready) _ScanGuideOverlay(stage: _stage),

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

          // 개발용 임시 버튼: 카메라/정렬 인식 없이 바로 스캔된 것으로 처리
          Positioned(
            bottom: 24,
            right: 16,
            child: FloatingActionButton.extended(
              heroTag: 'debug_force_scan',
              onPressed: _debugForceScan,
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
  const _ScanGuideOverlay({required this.stage});

  final _ScanStage stage;

  String get _hintText => switch (stage) {
        _ScanStage.positioning => '티켓을 사각형 안에 맞춰주세요',
        _ScanStage.aligned => '인식 완료!',
        _ScanStage.capturing => '스캔 중...',
      };

  Color get _borderColor => switch (stage) {
        _ScanStage.positioning => Colors.white70,
        _ScanStage.aligned || _ScanStage.capturing => const Color(0xFF34D399),
      };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final guideWidth = constraints.maxWidth * 0.86;
        final guideHeight = guideWidth / 2.15; // 콘서트 티켓처럼 가로가 긴 비율
        final guideRect = Rect.fromCenter(
          center: Offset(constraints.maxWidth / 2, constraints.maxHeight / 2 - 30),
          width: guideWidth,
          height: guideHeight,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            // 가이드 박스 바깥은 블러 + 어둡게 처리
            ClipPath(
              clipper: _OutsideGuideClipper(guideRect: guideRect, radius: 18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: Container(color: Colors.black.withValues(alpha: 0.45)),
              ),
            ),

            // 가이드 박스 테두리(정렬되면 초록색으로 전환)
            Positioned.fromRect(
              rect: guideRect.inflate(2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
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
