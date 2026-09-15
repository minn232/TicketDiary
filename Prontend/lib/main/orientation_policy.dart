import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 화면의 짧은 변(현재 방향과 무관하게 항상 같은 값) 기준으로 폰/태블릿을
/// 구분해 허용 방향을 정합니다 — 폰은 세로 고정(다이어리 UI가 세로 비율
/// 전제), 태블릿(가로모드 2페이지 스프레드 쓰는 크기)만 가로도 허용.
/// [MediaQuery] 변경(회전/폴더블/창 크기)마다 [build]가 재계산합니다.
///
/// 안드로이드 17 이상 대형화면은 세로만 요청해도 OS가 무시하고 가로
/// 회전을 허용하지만, 이 위젯은 그와 별개로 의도한 정책을 명시적으로
/// 선언해둡니다.
class OrientationPolicy extends StatefulWidget {
  final Widget child;

  const OrientationPolicy({super.key, required this.child});

  /// 이 값(dp) 이상이면 태블릿으로 봅니다 — Flutter/Material 커뮤니티에서
  /// 흔히 쓰는 태블릿 분기 기준(600dp)과 동일합니다.
  static const double tabletShortestSideThreshold = 600;

  @override
  State<OrientationPolicy> createState() => _OrientationPolicyState();
}

class _OrientationPolicyState extends State<OrientationPolicy> {
  bool? _appliedIsTabletSize;

  @override
  Widget build(BuildContext context) {
    final shortestSide = MediaQuery.sizeOf(context).shortestSide;
    final isTabletSize =
        shortestSide >= OrientationPolicy.tabletShortestSideThreshold;

    // 매 build마다 플랫폼 채널을 다시 부르지 않도록, 분류가 실제로
    // 바뀔 때만 반영합니다.
    if (_appliedIsTabletSize != isTabletSize) {
      _appliedIsTabletSize = isTabletSize;
      // setPreferredOrientations는 이 build() 도중(위젯 트리 구성 중)
      // 바로 부르기보다, 프레임이 끝난 뒤로 미뤄서 부작용 호출이 빌드
      // 단계와 겹치지 않게 합니다.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SystemChrome.setPreferredOrientations(
          isTabletSize
              ? const [
                  DeviceOrientation.portraitUp,
                  DeviceOrientation.portraitDown,
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]
              : const [
                  DeviceOrientation.portraitUp,
                  DeviceOrientation.portraitDown,
                ],
        );
      });
    }

    return widget.child;
  }
}
