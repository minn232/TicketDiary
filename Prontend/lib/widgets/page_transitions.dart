import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'diary_tabs.dart';

/// 페이지 넘김 방향
///
/// - [rightToLeft]: (우선순위 높은 → 낮은) 오른쪽 아래에서 시작해 왼쪽으로 넘김
/// - [leftToRight]: (우선순위 낮은 → 높은) 왼쪽 아래에서 시작해 오른쪽으로 넘김
enum DiaryPageTurnDirection { rightToLeft, leftToRight }

/// 화면(라우트) 우선순위
///
/// 숫자가 작을수록 우선순위가 높습니다.
int diaryRoutePriority(String? routeName) {
  switch (routeName) {
    case DiaryRoutes.diary:
      return 1;
    case DiaryRoutes.news:
      return 2;
    case DiaryRoutes.summary:
      return 3;
    case DiaryRoutes.settings:
      return 4;
    case DiaryRoutes.concertBefore:
      return 5;
    case DiaryRoutes.concertAfter:
      return 6;
    case DiaryRoutes.favoritePinned:
      return 7;
    default:
      return 999;
  }
}

/// 라우트별 "넘김 방향" 저장소
///
/// PageTransitionsBuilder는 이전/다음 라우트를 직접 알 수 없어서,
/// NavigatorObserver에서 push 시점에 방향을 계산해 저장해둔 값을 사용합니다.
class DiaryPageTurnStore {
  static final Map<Route<dynamic>, DiaryPageTurnDirection> _directionByRoute = {};

  static void set(Route<dynamic> route, DiaryPageTurnDirection direction) {
    _directionByRoute[route] = direction;
  }

  static DiaryPageTurnDirection get(Route<dynamic> route) {
    return _directionByRoute[route] ?? DiaryPageTurnDirection.rightToLeft;
  }

  static void remove(Route<dynamic> route) {
    _directionByRoute.remove(route);
  }
}

/// 우선순위 기반으로 종이 넘김 방향을 계산하는 NavigatorObserver
class DiaryNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);

    final from = diaryRoutePriority(previousRoute?.settings.name);
    final to = diaryRoutePriority(route.settings.name);

    final direction = (from < to)
        ? DiaryPageTurnDirection.rightToLeft
        : DiaryPageTurnDirection.leftToRight;

    DiaryPageTurnStore.set(route, direction);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (oldRoute != null) DiaryPageTurnStore.remove(oldRoute);
    if (newRoute == null) return;

    final from = diaryRoutePriority(oldRoute?.settings.name);
    final to = diaryRoutePriority(newRoute.settings.name);
    final direction = (from < to)
        ? DiaryPageTurnDirection.rightToLeft
        : DiaryPageTurnDirection.leftToRight;

    DiaryPageTurnStore.set(newRoute, direction);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    DiaryPageTurnStore.remove(route);
  }
}

/// 화면 전환을 "페이지를 넘기는" 느낌으로 보이게 하는 전환 빌더.
///
/// - 새 화면: bottom corner를 축으로 3D 회전하며 들어옴(종이 넘김)
/// - 기존 화면: 살짝 밀림(패럴랙스) + 약간 축소 + 약한 암전
///
/// `ThemeData.pageTransitionsTheme`에 등록하면
/// `MaterialPageRoute`, `Navigator.pushNamed` 등 대부분의 화면 전환에 자동 적용됩니다.
class DiaryPageTransitionsBuilder extends PageTransitionsBuilder {
  const DiaryPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // NOTE:
    // route.isFirst 인 경우에도(예: pushNamedAndRemoveUntil로 스택을 비운 뒤
    // 새 라우트를 push하면, 새 라우트가 곧바로 첫 번째가 됨)
    // 탭 전환 애니메이션이 사라지는 문제가 있습니다.
    // 초기 라우트는 animation 값이 이미 완료(1.0) 상태라 시각적 변화가 없으므로,
    // 여기서 별도 예외 처리를 두지 않고 항상 동일한 전환을 적용합니다.

    final direction = DiaryPageTurnStore.get(route);
    final sign = (direction == DiaryPageTurnDirection.rightToLeft) ? 1.0 : -1.0;

    final a = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final s = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    final exitOffset = Tween<Offset>(
      begin: Offset.zero,
      end: Offset(-0.08 * sign, 0.0),
    ).chain(CurveTween(curve: Curves.easeOutCubic));

    final bgScale = Tween<double>(begin: 1.0, end: 0.985)
        .chain(CurveTween(curve: Curves.easeOutCubic));

    // 한 child에
    // - secondaryAnimation(배경 상태일 때): 패럴랙스/축소/암전
    // - animation(전면 push/pop): 종이 넘김
    // 을 중첩 적용합니다.
    return SlideTransition(
      position: s.drive(exitOffset),
      child: ScaleTransition(
        scale: s.drive(bgScale),
        child: _DimOverlay(
          progress: s,
          child: _PaperFlip(
            progress: a,
            direction: direction,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 새 페이지를 "종이 넘김"처럼 보이게 하는 3D 회전 트랜지션
class _PaperFlip extends StatelessWidget {
  final Animation<double> progress;
  final DiaryPageTurnDirection direction;
  final Widget child;

  const _PaperFlip({
    required this.progress,
    required this.direction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, child) {
        final t = progress.value.clamp(0.0, 1.0);

        final sign = (direction == DiaryPageTurnDirection.rightToLeft) ? 1.0 : -1.0;

        // ±90deg -> 0deg (Y축)
        final angleY = (math.pi / 2) * (1 - t) * sign;

        // 종이 굴곡(들림)을 위해 X/Z도 살짝 섞음
        final angleX = (math.pi / 18) * (1 - t); // 약 10도
        final angleZ = (math.pi / 55) * (1 - t) * -sign; // 약 3.3도

        final fade = Tween<double>(begin: 0.0, end: 1.0)
            .transform(t);

        final transform = Matrix4.identity()
          ..setEntry(3, 2, 0.0021) // perspective
          ..rotateX(angleX)
          ..rotateY(angleY)
          ..rotateZ(angleZ);

        // 접힘 그림자/하이라이트(진입 초반 강하고, 완료 시 사라짐)
        final shadowOpacity = (1 - t).clamp(0.0, 1.0);
        final highlightOpacity = (1 - t).clamp(0.0, 1.0);

        final alignment = (direction == DiaryPageTurnDirection.rightToLeft)
            ? Alignment.bottomRight
            : Alignment.bottomLeft;

        final gradientBegin = (direction == DiaryPageTurnDirection.rightToLeft)
            ? Alignment.centerRight
            : Alignment.centerLeft;
        final gradientEnd = (direction == DiaryPageTurnDirection.rightToLeft)
            ? Alignment.centerLeft
            : Alignment.centerRight;

        final corner = alignment;

        return Opacity(
          opacity: fade,
          child: Transform(
            alignment: alignment,
            transform: transform,
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                child!,
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // 굴곡(접힘선) 명암을 강조
                      gradient: LinearGradient(
                        begin: gradientBegin,
                        end: gradientEnd,
                        colors: [
                          Colors.black.withValues(alpha: 0.22 * shadowOpacity),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.12 * shadowOpacity),
                        ],
                        stops: const [0.0, 0.48, 1.0],
                      ),
                    ),
                  ),
                ),

                // 코너 근처의 깊은 음영
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: corner,
                        radius: 1.15,
                        colors: [
                          Colors.black.withValues(alpha: 0.22 * shadowOpacity),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.7],
                      ),
                    ),
                  ),
                ),

                // 접힘선 하이라이트(빛 반사)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: corner,
                        radius: 0.95,
                        colors: [
                          Colors.white.withValues(alpha: 0.20 * highlightOpacity),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.65],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 배경 페이지를 살짝 어둡게 만들어 "종이"가 위로 올라온 느낌을 강화
class _DimOverlay extends StatelessWidget {
  final Animation<double> progress;
  final Widget child;

  const _DimOverlay({required this.progress, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, child) {
        final t = progress.value.clamp(0.0, 1.0);
        return Stack(
          fit: StackFit.passthrough,
          children: [
            child!,
            IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.06 * t),
              ),
            ),
          ],
        );
      },
    );
  }
}


