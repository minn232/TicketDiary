import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/models/artist_model.dart';
import 'package:ticketdiary/screen/favorite_pinned_settings_screen.dart';
import 'package:ticketdiary/services/artist_recommendation_service.dart';
import 'package:ticketdiary/services/artist_search_service.dart';

class _FakeArtistRecommendationService implements ArtistRecommendationService {
  const _FakeArtistRecommendationService(this.artists);

  final List<ArtistModel> artists;

  @override
  Future<List<ArtistModel>> getRecommendations({int limit = 20}) async =>
      artists;
}

// [백엔드 수정]
// 실제 네트워크 없이 자동 검색(디바운스) 트리거 여부를 세기 위한 가짜 서비스.
class _FakeArtistSearchService implements ArtistSearchService {
  _FakeArtistSearchService(this.results);

  final List<ArtistModel> results;
  int callCount = 0;

  @override
  Future<List<ArtistModel>> search(String query) async {
    callCount++;
    return results;
  }
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
  // 엔터 전용 -> 타이핑 디바운스(250ms) 자동 검색 회귀 테스트.
  testWidgets('타이핑하면 디바운스 후 자동으로 검색된다', (tester) async {
    final artistSearchService = _FakeArtistSearchService([
      const ArtistModel(name: '아이유', profileImageUrl: ''),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: FavoritePinnedSettingsScreen(
          artistSearchService: artistSearchService,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), '아이유');
    // 디바운스(250ms) 전엔 검색이 안 걸렸어야 하지만, 스피너는 입력 즉시 뜸.
    await tester.pump(const Duration(milliseconds: 100));
    expect(artistSearchService.callCount, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 디바운스 이후엔 자동으로 검색이 걸리고 결과가 뜸.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(artistSearchService.callCount, 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
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
