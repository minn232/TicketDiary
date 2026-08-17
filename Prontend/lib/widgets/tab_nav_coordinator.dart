import 'package:flutter/material.dart';

import 'diary_route.dart';

/// 인덱스 탭(다이어리/소식/결산/설정) 전환을 조율합니다.
///
/// 각 화면 자신의 탭([diary_tabs.dart]의 `buildDiarySideTabs`)은 화면
/// 전체와 함께 슬라이드 전환되는 위젯 트리 안에 있어서, 전환 애니메이션이
/// 진행되는 동안(기본 MaterialPageRoute 기준 수백ms) 다음 탭이 아직 최종
/// 위치에 도착하지 않은 순간이 있습니다. 이때 빠르게 연속으로 탭을 누르면
/// 실제로는 그 자리에 아무 위젯도 없어(아직 슬라이드해 들어오는 중이라)
/// 눌림이 그냥 허공을 짚어 무시되는 것처럼 보였습니다.
///
/// 이 코디네이터는 "지금 전환 중인지"를 추적해서: 유휴 상태면 즉시 전환을
/// 시작하고, 이미 전환 중이면 마지막으로 요청된 탭만 기억해뒀다가 현재
/// 전환이 끝나는 즉시 이어서 실행합니다 — 입력을 잃지 않으면서도 기존
/// 슬라이드 애니메이션은 그대로 유지합니다. [TabHitCatcherOverlay]가
/// [isTransitioning]이 true인 동안만 나타나는, 화면 전환과 무관하게 항상
/// 같은 자리에 있는 보이지 않는 눌림 받이 역할을 합니다.
class TabNavCoordinator {
  TabNavCoordinator._({
    required this.navigatorKey,
    required this.routeBuilder,
    required DiaryTab initialTab,
  })  : currentTab = ValueNotifier(initialTab),
        isTransitioning = ValueNotifier(false);

  static TabNavCoordinator? _instance;

  /// 앱 시작 시([TicketDiaryApp]) 한 번만 호출해 초기화합니다. 이미
  /// 초기화돼 있으면(예: build()가 여러 번 호출돼도) 기존 인스턴스를
  /// 그대로 반환합니다.
  static TabNavCoordinator init({
    required GlobalKey<NavigatorState> navigatorKey,
    required PageRoute<void> Function(DiaryTab from, DiaryTab to) routeBuilder,
    DiaryTab initialTab = DiaryTab.diary,
  }) {
    return _instance ??= TabNavCoordinator._(
      navigatorKey: navigatorKey,
      routeBuilder: routeBuilder,
      initialTab: initialTab,
    );
  }

  static TabNavCoordinator get instance {
    final i = _instance;
    assert(i != null, 'TabNavCoordinator.init()을 먼저 호출해야 합니다.');
    return i!;
  }

  /// 테스트에서만 씁니다 — 각 테스트가 자기만의 navigatorKey/routeBuilder로
  /// 새 인스턴스를 초기화할 수 있도록 싱글턴을 비웁니다.
  @visibleForTesting
  static void resetForTest() {
    _instance = null;
  }

  final GlobalKey<NavigatorState> navigatorKey;

  /// 목적지 라우트를 만듭니다. [from](지금 탭)을 함께 받는 이유는, 페이지
  /// 넘김 전환([DiaryTabFlipRoute])이 탭 번호가 커지는 이동인지 작아지는
  /// 이동인지에 따라 앞/뒤 넘김 방향을 골라야 하기 때문입니다.
  final PageRoute<void> Function(DiaryTab from, DiaryTab to) routeBuilder;

  /// 지금 보여주고 있거나(유휴 상태) 향하고 있는(전환 중) 탭.
  final ValueNotifier<DiaryTab> currentTab;
  final ValueNotifier<bool> isTransitioning;

  /// 전환 중에 새로 요청된, 아직 처리 못 한 다음 목적지. 여러 번 요청되면
  /// 마지막 것만 남습니다(중간 탭들은 건너뜀).
  DiaryTab? _queuedTab;

  void requestTab(DiaryTab tab) {
    if (tab == currentTab.value) {
      // 지금 보여주고 있거나(유휴) 이미 향하고 있는(전환 중) 탭을 다시
      // 요청한 것 — 이전에 큐에 쌓여 있던 다른 목적지가 있었다면, 사용자의
      // 가장 최근 의도(여기 머무름)로 덮어써서 취소합니다.
      _queuedTab = null;
      return;
    }
    if (isTransitioning.value) {
      _queuedTab = tab;
      return;
    }
    _start(tab);
  }

  void _start(DiaryTab tab) {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    final from = currentTab.value;
    currentTab.value = tab;
    isTransitioning.value = true;
    _queuedTab = null;

    final route = routeBuilder(from, tab);
    // (r) => false: 스택에 남은 라우트를 전부 제거하고 이 라우트 하나만
    // 남깁니다. 예전엔 (r) => r.isFirst를 썼는데, Route.isFirst는 "지금
    // 스택 맨 밑"이라는 뜻이라 스플래시 직후 처음 만들어진 다이어리 화면
    // 인스턴스가 절대 제거되지 않고 영원히 스택 바닥에 남아있었습니다.
    // 그 상태에서 다이어리 탭에 다시 들어가면 완전히 새 DiaryScreen
    // 인스턴스가 그 위에 또 쌓이는데, 둘 다 static _tickets(같은
    // TicketData 인스턴스, 같은 overlayKey/posterOverlayKey)를 그대로
    // 참조해 동시에 마운트되면서 "Duplicate GlobalKey" 예외가 났습니다
    // (탭을 여러 번 오가며 실제 시뮬레이터에서 재현 후 발견). 탭 전환은
    // 항상 화면 하나만 스택에 있으면 되고(뒤로가기는 PopScope로 별도
    // 처리되므로 스택 깊이에 의존하지 않음), 비워도 push가 곧장 새
    // 라우트를 넣어주므로 안전합니다.
    navigator.pushAndRemoveUntil(route, (r) => false);

    // 전환(진입) 애니메이션이 고정 시간만 재생되고 끝나면 곧바로 잠금을
    // 풀고, 그 사이 대기 중이던 다음 탭이 있으면 이어서 시작합니다. 소식
    // 탭도 더 이상 로딩을 기다리지 않으므로(진입 즉시 목적지를 드러냄)
    // 특별 취급 없이 모든 탭이 동일하게 애니메이션 완료 시점에 풀립니다.
    void unlockAndMaybeAdvance() {
      isTransitioning.value = false;
      final next = _queuedTab;
      if (next != null && next != tab) {
        _start(next);
      }
    }

    late final AnimationStatusListener animListener;
    animListener = (status) {
      if (status != AnimationStatus.completed) return;
      route.animation?.removeStatusListener(animListener);
      unlockAndMaybeAdvance();
    };
    route.animation?.addStatusListener(animListener);
  }
}
