import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/screen/news_detail_overlay.dart';

/// 소식 상세의 포스터 확대 화면에서: 더블탭으로 확대/축소되고(InteractiveViewer
/// 의 transformationController로 확인), 포스터 자체를 눌러선 안 닫히고
/// 포스터 바깥(여백)을 눌러야 닫히는지 검증합니다.
void main() {
  Future<void> doubleTapAt(WidgetTester tester, Offset location) async {
    await tester.tapAt(location);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(location);
    await tester.pumpAndSettle();
  }

  Future<void> openPosterOverlay(WidgetTester tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final news = NewsModel(
      artist: '아티스트',
      concert: '테스트 공연',
      imageUrl: '',
      description: '',
      articleImageUrl: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NewsDetailOverlay(
          startRect: const Rect.fromLTWH(0, 0, 100, 100),
          collapsedCard: const SizedBox(),
          news: news,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 작은 포스터(확대 힌트 아이콘이 있는 자리)를 눌러 확대 레이어를 엽니다.
    await tester.tap(find.byIcon(Icons.zoom_in));
    await tester.pumpAndSettle();
  }

  testWidgets('포스터를 더블탭하면 확대되고, 다시 더블탭하면 원래대로 축소된다', (tester) async {
    await openPosterOverlay(tester);

    final viewerFinder = find.byType(InteractiveViewer);
    expect(viewerFinder, findsOneWidget);
    InteractiveViewer viewer() => tester.widget<InteractiveViewer>(viewerFinder);

    expect(viewer().transformationController!.value.getMaxScaleOnAxis(), closeTo(1.0, 0.01));

    await doubleTapAt(tester, tester.getCenter(viewerFinder));
    expect(viewer().transformationController!.value.getMaxScaleOnAxis(), greaterThan(1.5));

    await doubleTapAt(tester, tester.getCenter(viewerFinder));
    expect(viewer().transformationController!.value.getMaxScaleOnAxis(), closeTo(1.0, 0.01));
  });

  testWidgets('포스터 자체를 눌러도 확대 화면이 닫히지 않는다', (tester) async {
    await openPosterOverlay(tester);

    final viewerFinder = find.byType(InteractiveViewer);
    await tester.tap(viewerFinder);
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: viewerFinder, matching: find.byType(AnimatedOpacity)),
    );
    expect(opacity.opacity, 1.0);
  });

  testWidgets('포스터 바깥(여백)을 누르면 확대 화면이 닫힌다', (tester) async {
    await openPosterOverlay(tester);

    final opacityFinder = find.ancestor(
      of: find.byType(InteractiveViewer),
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 1.0);

    // 카드 안이지만 포스터가 차지하지 않는 자리(카드는 화면의 90%라
    // 화면 맨 구석은 카드 바깥 배경이라서 전체 상세 화면이 닫혀버림 —
    // 카드 안쪽, 포스터 위쪽 여백을 눌러야 "포스터만" 닫힙니다).
    await tester.tapAt(const Offset(30, 55));
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, 0.0);
  });
}
