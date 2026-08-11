/// 앱 전역에서 사용하는 탭 라우트 경로
abstract class DiaryRoutes {
  /// 앱 실행 시 보여주는 시작 애니메이션 화면(SplashScreen). 탭이 아니라서
  /// [diaryTabLayoutSpecs]에는 포함되지 않습니다.
  static const String splash = '/splash';

  static const String diary = '/';
  static const String news = '/news';
  static const String summary = '/summary';
  static const String settings = '/settings';

  /// 상세 화면(우선순위 기반 페이지 넘김 방향 결정을 위해 route name 부여)
  static const String concertBefore = '/concert/before';
  static const String concertAfter = '/concert/after';
  static const String favoritePinned = '/settings/favorite_pinned';

  // [백엔드 수정]
  // 인앱 알림함 화면 신규 추가로 라우트 이름 신규 추가.
  static const String notifications = '/settings/notifications';
}

enum DiaryTab { diary, news, summary, settings }

/// 인덱스 탭 하나의 위치(right/top)와 그 탭이 가리키는 라우트 이름.
///
/// [diary_tabs.dart]의 실제 화면별 탭(화면 전체와 함께 슬라이드 전환됨)과
/// [TabHitCatcherOverlay](화면 전환과 무관하게 항상 같은 자리에 떠 있는,
/// 보이지 않는 눌림 받이) 둘 다 이 값을 그대로 공유해서, 눈에 보이는
/// 탭과 보이지 않는 히트 영역이 완전히 같은 자리에 겹치도록 맞춥니다.
class DiaryTabLayoutSpec {
  final DiaryTab tab;
  final double right;
  final double top;
  final String routeName;
  const DiaryTabLayoutSpec({
    required this.tab,
    required this.right,
    required this.top,
    required this.routeName,
  });
}

// right 값: 모든 탭을 같은 x축 위치(4)로 통일합니다 — 비활성 탭도 이
// 위치에서 글씨가 전부 보이고 탭 전체가 눌리는 영역이 됩니다.
//
// top 값: 다이어리~소식~결산 사이의 간격을 8.75로 좁혔습니다. 설정 탭
// 위치(315)는 그대로 유지합니다.
const double diaryTabRight = 4.0;

const List<DiaryTabLayoutSpec> diaryTabLayoutSpecs = [
  DiaryTabLayoutSpec(
    tab: DiaryTab.diary,
    right: diaryTabRight,
    top: 56, // = 80 * 0.7 (변경 없음, 나머지 탭의 기준점)
    routeName: DiaryRoutes.diary,
  ),
  DiaryTabLayoutSpec(
    tab: DiaryTab.news,
    right: diaryTabRight,
    top: 127.75, // 다이어리 바로 아래(56+63) + 간격 8.75
    routeName: DiaryRoutes.news,
  ),
  DiaryTabLayoutSpec(
    tab: DiaryTab.summary,
    right: diaryTabRight,
    top: 199.5, // 소식 바로 아래(127.75+63) + 간격 8.75
    routeName: DiaryRoutes.summary,
  ),
  DiaryTabLayoutSpec(
    tab: DiaryTab.settings,
    right: diaryTabRight,
    top: 450 * 0.7, // 변경 없음(요청대로 위치 유지)
    routeName: DiaryRoutes.settings,
  ),
];

String routeNameForDiaryTab(DiaryTab tab) =>
    diaryTabLayoutSpecs.firstWhere((s) => s.tab == tab).routeName;
