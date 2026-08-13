import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/screen/favorite_pinned_settings_screen.dart';

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
}
