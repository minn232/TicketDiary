import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'diary_page_frame.dart';
import 'diary_route.dart';
import 'responsive_text.dart';
import 'tab_nav_coordinator.dart';

/// [TabNavCoordinator.isTransitioning]이 true인 동안만 나타나는, 눈에
/// 보이지 않는 인덱스 탭 히트 영역.
///
/// 각 화면 자신의 인덱스 탭(diary_tabs.dart의 buildDiarySideTabs)은 화면
/// 전체와 함께 슬라이드 전환되므로, 전환 도중엔 다음 탭이 아직 최종
/// 위치에 없어 그 자리를 눌러도 반응이 없었습니다([TabNavCoordinator]
/// 문서 참고). 이 오버레이는 [MaterialApp.builder]를 통해 Navigator
/// 위(전환과 무관하게 항상 같은 화면 좌표)에 고정돼 있어서, 전환 중에도
/// "탭이 최종적으로 있을 자리"에 눌림을 받아둘 수 있습니다.
///
/// 평소(전환 중이 아닐 때)는 완전히 사라져서, 실제 화면의 탭
/// (PressableScale 팝 애니메이션 포함)이 정상적으로 눌림을 처리하도록
/// 비켜둡니다.
class TabHitCatcherOverlay extends StatelessWidget {
  final TabNavCoordinator coordinator;
  const TabHitCatcherOverlay({super.key, required this.coordinator});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: coordinator.isTransitioning,
      builder: (context, transitioning, _) {
        if (!transitioning) return const SizedBox.shrink();
        // DiaryPageFrame.build()와 완전히 같은 기하 계산(아이패드처럼
        // 화면비가 넓은 기기에서 좌우로 남는 여백까지)을 그대로 재현해야
        // 실제 탭과 픽셀 단위로 같은 자리에 겹칩니다.
        return SafeArea(
          child: LayoutBuilder(
            builder: (context, outerConstraints) {
              final availableWidth = outerConstraints.maxWidth;
              return Center(
                child: AspectRatio(
                  aspectRatio: DiaryPageFrame.diaryAspectRatio,
                  child: LayoutBuilder(
                    builder: (context, innerConstraints) {
                      final frameWidth = innerConstraints.maxWidth;
                      final scale = (frameWidth / kReferenceFrameWidth)
                          .clamp(kMinTextScale, kMaxTextScale);
                      final marginEachSide =
                          math.max(0.0, (availableWidth - frameWidth) / 2);
                      return Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (final layout in diaryTabLayoutSpecs)
                            DiaryPageFrame.buildScaledSideTab(
                              DiarySideTabSpec(
                                right: layout.right,
                                top: layout.top,
                                // 보이지 않아도 됩니다 — PressableScale이
                                // HitTestBehavior.opaque라 이 자리 전체가
                                // (자식이 그리는 게 없어도) 눌림을 받습니다.
                                child: const SizedBox(),
                                onTap: () => coordinator.requestTab(layout.tab),
                              ),
                              scale,
                              marginEachSide,
                            ),
                        ],
                      );
                    },
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
