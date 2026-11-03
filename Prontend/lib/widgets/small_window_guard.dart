import 'package:flutter/material.dart';

import 'paper_style.dart';

/// [백엔드 수정] 분할 화면에서 창이 너무 작아지면 깨진 화면 대신 안내 메모를 덮음.
/// 분할 화면 크기는 앱이 막을 수 없어(안드로이드 12+ 큰 화면은 resizeableActivity 무시)
/// 아래 화면 상태는 그대로 두고 덮기만 함 - 창을 넓히면 보던 화면으로 바로 돌아옴
class SmallWindowGuard extends StatelessWidget {
  const SmallWindowGuard({super.key});

  /// 가장 작은 폰(폭 약 360)과 폰 가로 화면(높이 약 360)에서는 안 뜨는 기준
  static const double minWidth = 320;
  static const double minHeight = 300;

  static bool tooSmall(Size size) =>
      size.width < minWidth || size.height < minHeight;

  @override
  Widget build(BuildContext context) {
    if (!tooSmall(MediaQuery.sizeOf(context))) return const SizedBox.shrink();
    return Material(
      key: const ValueKey('small-window-guard'),
      color: const Color(0xFF5A4031),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                Container(
                  constraints: const BoxConstraints(maxWidth: 240),
                  padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
                  decoration: BoxDecoration(
                    color: PaperColors.card,
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .25),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '화면이 너무 좁아요',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: PaperColors.ink,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        '창을 조금 넓히면\n다이어리가 다시 펼쳐져요',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: PaperColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const Positioned(
                  top: -8,
                  child: MaskingTape(width: 56, height: 16),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
