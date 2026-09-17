import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/widgets/diary_page_frame.dart';

/// [DiaryPageFrame.frameAbovePage](소식 탭 풀탭 등, 프레임 상단 경계 밖으로
/// 삐져나오는 자유 레이어)는 예전엔 [DiaryPageFrame]의 내부 Stack(정확히
/// frameHeight로 타이트하게 제약됨) 안에 top이 음수인 Positioned로
/// 그려졌는데, Flutter는 부모 자신의 크기(0~frameHeight) 밖의 위치는
/// hitTestChildren까지도 진입시키지 않아서, 화면엔 보여도 그 프레임 밖으로
/// 나간 부분은 실제로 눌리지 않는 문제가 있었습니다(태블릿 실기기에서
/// 풀탭 위쪽 절반이 안 눌리는 버그로 발견). build()의 바깥쪽 Stack(진짜
/// 여유 공간이 있는)에서 따로 그리도록 고쳤고, 이 테스트가 그 회귀를
/// 직접 잡습니다.
void main() {
  testWidgets(
    '태블릿형(화면비가 넓은) 기기에서도 frameAbovePage의 프레임 밖(음수 좌표) 영역이 탭된다',
    (tester) async {
      // diaryAspectRatio(≈0.568)보다 넓은 화면비 - 세로가 꽉 차서 위아래
      // 여백이 원래 0인, indexTabTopReserve가 실제로 효과를 내는 케이스.
      tester.view.physicalSize = const Size(1600, 2560);
      tester.view.devicePixelRatio = 2.125;
      addTearDown(tester.view.reset);

      var tapped = false;
      const topOverflow = 40.0;
      const targetKey = ValueKey('overflow-target');

      await tester.pumpWidget(
        MaterialApp(
          home: DiaryPageFrame(
            isTabRoot: true,
            showBinderRings: false,
            frameAbovePage: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 10,
                  // frameAbovePage 자신의 박스는 이미 -topOverflow만큼
                  // 밀려 있으므로(실제 NewsPullTabHitAreaOverlay와 같은
                  // 구조), 그 안에서 다시 살짝(-6) 위로 걸치게 배치 -
                  // 실제 풀탭의 topY(≈pageTop+overflow-tabHeight) 패턴.
                  top: -6,
                  width: 80,
                  height: topOverflow,
                  child: GestureDetector(
                    key: targetKey,
                    behavior: HitTestBehavior.opaque,
                    onTap: () => tapped = true,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
            frameAbovePageTopOverflow: topOverflow,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 프레임 자신의 상단 경계보다 위(overflow 영역)에 있는 위젯을 직접
      // 탭합니다 - 실제 풀탭이 상태바 바로 아래 삐져나온 자리를 누르는
      // 것과 동일한 시나리오입니다. warnIfMissed: false - getCenter가
      // PressableScale 등 중간 래퍼 때문에 약간 다른 좌표를 골라도(다른
      // 위젯 테스트에서도 흔한 진단성 경고) 실제로 탭됐는지(expect)만
      // 신뢰합니다.
      await tester.tap(find.byKey(targetKey), warnIfMissed: false);
      await tester.pump();

      expect(tapped, isTrue);
    },
  );
}
