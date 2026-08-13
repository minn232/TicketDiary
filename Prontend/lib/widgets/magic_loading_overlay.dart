import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 최신 소식을 준비하는 동안 페이지 위에 "약한 마법이 걸린 듯한" 느낌을
/// 주는 오버레이 — 살짝 투명한 하얀 안개 + 곳곳에서 은은하게 반짝이는
/// 작은 별들(auto_awesome).
///
/// 순수 장식용이라 터치는 막지 않습니다([IgnorePointer]) — 필요하면 부모가
/// 별도 배리어를 둡니다.
class MagicLoadingOverlay extends StatefulWidget {
  const MagicLoadingOverlay({super.key});

  @override
  State<MagicLoadingOverlay> createState() => _MagicLoadingOverlayState();
}

class _MagicLoadingOverlayState extends State<MagicLoadingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const _glowColor = Color(0xFFFFF3C4);

  /// 반짝이들의 고정 배치(화면 비율 좌표 0~1) + 위상/크기 편차. 매번
  /// 무작위로 흩뿌리지 않고 고정해서, 로딩 중 안정적으로 같은 자리에서
  /// 깜빡이도록 합니다.
  static const List<_Sparkle> _sparkles = [
    _Sparkle(0.18, 0.22, 0.0, 15),
    _Sparkle(0.72, 0.16, 0.7, 12),
    _Sparkle(0.44, 0.35, 1.5, 18),
    _Sparkle(0.83, 0.44, 2.3, 13),
    _Sparkle(0.28, 0.55, 3.0, 16),
    _Sparkle(0.62, 0.63, 3.8, 12),
    _Sparkle(0.14, 0.74, 4.5, 14),
    _Sparkle(0.5, 0.82, 5.2, 17),
    _Sparkle(0.86, 0.78, 5.9, 11),
    _Sparkle(0.36, 0.12, 2.0, 10),
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final basePhase = _controller.value * 2 * math.pi;
          // 안개 농도도 아주 약하게 숨쉬듯 오르내립니다.
          final veil = 0.18 + (math.sin(basePhase) + 1) / 2 * 0.14;

          return Stack(
            fit: StackFit.expand,
            children: [
              // 살짝 투명한 하얀 안개. 가운데가 조금 더 밝은 방사형 그라데이션.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 1.1,
                    colors: [
                      Colors.white.withValues(alpha: veil + 0.10),
                      Colors.white.withValues(alpha: veil),
                    ],
                  ),
                ),
              ),
              for (final s in _sparkles) _buildSparkle(s, basePhase),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSparkle(_Sparkle s, double basePhase) {
    final phase = basePhase + s.phaseOffset;
    final twinkle = ((math.sin(phase) + 1) / 2).clamp(0.0, 1.0);
    // 위아래로 살짝 떠다니는 느낌.
    final floatDy = math.sin(phase * 0.7) * 3;

    // 화면 비율 좌표(0~1)를 Alignment(-1~1)로 바꿔 배치합니다 —
    // LayoutBuilder 없이도 크기에 비례해 놓입니다.
    return Align(
      alignment: Alignment(s.fx * 2 - 1, s.fy * 2 - 1),
      child: Transform.translate(
        offset: Offset(0, floatDy),
        child: Opacity(
          opacity: 0.25 + twinkle * 0.75,
          child: Icon(
            Icons.auto_awesome,
            size: s.size * (0.75 + twinkle * 0.5),
            color: _glowColor,
            shadows: [
              Shadow(
                color: _glowColor.withValues(alpha: 0.8),
                blurRadius: 6 + twinkle * 8,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sparkle {
  /// 화면 비율 좌표(0~1).
  final double fx;
  final double fy;

  /// 깜빡임 위상 오프셋(라디안).
  final double phaseOffset;

  /// 기준 크기(px).
  final double size;

  const _Sparkle(this.fx, this.fy, this.phaseOffset, this.size);
}
