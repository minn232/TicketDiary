import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/screen/news_detail_overlay.dart';

/// 소식 카드를 눌렀을 때 뜨는 상세 오버레이가 레이아웃 예외 없이 열리는지
/// 검증합니다. 3정보 타일 Row에 CrossAxisAlignment.stretch를 준 채
/// SingleChildScrollView(세로 무한 높이) 안에 넣으면 무한 제약으로
/// RenderFractionallySizedOverflowBox가 터졌던 회귀를 막습니다.
void main() {
  testWidgets('소식 상세 오버레이가 예외 없이 열리고 제목/정보 타일/예매처가 보인다', (tester) async {
    final news = NewsModel(
      artist: '아티스트',
      concert: '테스트 공연 [서울]',
      imageUrl: '',
      description: '',
      venue: '서울 공연장',
      ticketingLinks: const {
        'MELON': 'https://melon.example',
        'INTERPARK': 'https://interpark.example',
      },
      periodText: '2026.09.04 ~ 09.06',
      ticketingText: 'D-3',
      isFavoritedConcert: true,
      concertDate: DateTime(2026, 9, 4),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => NewsDetailOverlay.show(
                  ctx,
                  startRect: const Rect.fromLTWH(20, 20, 120, 160),
                  collapsedCard: const SizedBox(),
                  news: news,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 레이아웃 예외가 없어야 합니다(회귀 방지의 핵심).
    expect(tester.takeException(), isNull);

    // 상세 콘텐츠가 실제로 그려집니다.
    expect(find.text('테스트 공연 [서울]'), findsOneWidget);
    expect(find.text('공연 기간'), findsOneWidget);
    expect(find.text('공연장'), findsOneWidget);
    expect(find.text('티켓팅 날짜'), findsOneWidget);
    expect(find.text('멜론티켓에서 예매하기'), findsOneWidget);
    expect(find.text('인터파크에서 예매하기'), findsOneWidget);
  });
}
