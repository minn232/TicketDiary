import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/news_model.dart';
import 'package:ticketdiary/models/ticket_scan.dart';
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
                  frameScale: 1.0,
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

  // [백엔드 수정]
  // 예매 단계(선예매/1차/2차) 표시 UI 회귀 테스트 - 타일엔 다음 단계만
  // 요약해서 뜨고, 탭하면 전체 단계 목록 다이얼로그가 뜸.
  testWidgets('예매 단계 정보가 있으면 다음 단계가 요약되고 탭하면 전체 단계가 보인다', (
    tester,
  ) async {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final news = NewsModel(
      artist: '아티스트',
      concert: '테스트 공연 [단계]',
      imageUrl: '',
      description: '',
      venue: '서울 공연장',
      periodText: '2026.09.04 ~ 09.06',
      concertDate: DateTime(2026, 9, 4),
      ticketingPhases: [
        TicketingPhaseEntry(
          phase: '선예매',
          date: todayDate.subtract(const Duration(days: 10)),
        ),
        TicketingPhaseEntry(
          phase: '일반예매',
          date: todayDate.add(const Duration(days: 5)),
        ),
      ],
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
                  frameScale: 1.0,
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
    expect(tester.takeException(), isNull);

    // 이미 지난 "선예매"가 아니라 다가올 "일반예매"가 요약으로 뜸.
    expect(find.textContaining('일반예매 D-5'), findsOneWidget);

    await tester.tap(find.text('티켓팅 날짜'));
    await tester.pumpAndSettle();

    // 전체 단계(선예매/일반예매)가 목록으로 보임.
    expect(find.text('선예매'), findsOneWidget);
    expect(find.text('일반예매'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
