import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/models/artist_model.dart';
import 'package:ticketdiary/screen/favorite_pinned_settings_screen.dart';
import 'package:ticketdiary/services/artist_recommendation_service.dart';

class _FakeArtistRecommendationService implements ArtistRecommendationService {
  const _FakeArtistRecommendationService(this.artists);

  final List<ArtistModel> artists;

  @override
  Future<List<ArtistModel>> getRecommendations({int limit = 20}) async =>
      artists;
}

/// 선호 아티스트/찜 공연 검색이 한 화면 안에 세로로 같이 있던 것을 좌우
/// 스와이프로 나눈 개편을 검증합니다: 처음엔 아티스트 검색 페이지가
/// 보이고, "찜 공연" 알약을 누르면(또는 스와이프하면) 공연 검색 페이지로
/// 넘어가야 합니다.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('처음엔 아티스트 검색 페이지가 보인다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: FavoritePinnedSettingsScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('아티스트 이름 검색'), findsOneWidget);
  });

  testWidgets('"찜 공연" 알약을 누르면 공연 검색 페이지로 넘어간다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: FavoritePinnedSettingsScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('찜 공연'));
    // PageView.animateToPage 애니메이션이 끝날 때까지.
    await tester.pumpAndSettle();

    expect(find.text('공연 이름 검색'), findsOneWidget);
  });

  testWidgets('좌우로 스와이프하면 페이지가 넘어간다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: FavoritePinnedSettingsScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('아티스트 이름 검색'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.text('공연 이름 검색'), findsOneWidget);
  });

  // [백엔드 수정]
  // 타이핑마다 자동 검색하던 걸 엔터(키보드 검색) 시에만 검색하도록 바꾼
  // 회귀 테스트 - 타이핑만으로는 검색(네트워크 요청/로딩)이 시작되지 않아야 함.
  testWidgets('타이핑만으로는 검색이 실행되지 않고 "검색을 눌러주세요" 안내만 보인다', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: FavoritePinnedSettingsScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), '아이유');
    // 디바운스가 있었다면 여기서 자동 검색이 걸렸을 시간을 흘려보냄.
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('키보드에서 검색을 눌러주세요.'), findsOneWidget);
  });

  // 실기기(태블릿)에서 라벨 높이 고정값(34)이 반응형 배율보다 작아
  // "BOTTOM OVERFLOWED BY 1.00 PIXELS"가 나던 문제 수정(cardWidth +
  // context.rs(34)) - 1px 단위라 이 테스트에선 결정적 재현은 안 되고
  // 렌더링 자체는 무사한지 확인하는 스모크 테스트로 남김.
  testWidgets('추천 아티스트 그리드가 큰 배율에서도 오버플로우 없이 그려진다', (tester) async {
    const recommendationService = _FakeArtistRecommendationService([
      ArtistModel(name: '선우정아', profileImageUrl: ''),
      ArtistModel(name: '자우림', profileImageUrl: ''),
      ArtistModel(name: 'Vaundy', profileImageUrl: ''),
    ]);

    await tester.pumpWidget(
      const MaterialApp(
        home: FavoritePinnedSettingsScreen(
          recommendationService: recommendationService,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('자우림'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
