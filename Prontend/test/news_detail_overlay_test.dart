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

    // 이미 지난 "선예매"가 아니라 다가올 "일반예매"가 요약으로 뜸(단계/D-day
    // 각각 밑줄이 자기 줄 폭에 맞게 그려지도록 별도 Text로 렌더링됨).
    expect(find.text('일반예매'), findsOneWidget);
    expect(find.text('D-5'), findsOneWidget);

    await tester.tap(find.text('티켓팅 날짜'));
    await tester.pumpAndSettle();

    // 전체 단계(선예매/일반예매)가 목록으로 보임 - "일반예매"는 타일 요약(뒤)과
    // 다이얼로그 목록(앞) 둘 다에 남아있어 2개.
    expect(find.text('선예매'), findsOneWidget);
    expect(find.text('일반예매'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  // [백엔드 수정]
  // 공연장 이름에 옛 이름 괄호가 붙으면("예스24 라이브홀 (구. 악스코리아)")
  // 괄호 앞에서 줄바꿈해서 두 줄 다 각자 폭에 맞는 밑줄이 그려지는지 확인.
  testWidgets('공연장에 옛 이름 괄호가 있으면 그 앞에서 줄바꿈된다', (tester) async {
    final news = NewsModel(
      artist: '아티스트',
      concert: '테스트 공연 [서울]',
      imageUrl: '',
      description: '',
      venue: '예스24 라이브홀 (구. 악스코리아)',
      periodText: '2026.09.04 ~ 09.06',
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
    expect(tester.takeException(), isNull);

    expect(find.text('예스24 라이브홀'), findsOneWidget);
    expect(find.text('(구. 악스코리아)'), findsOneWidget);
  });

  // [백엔드 수정]
  // 공연 기간이 여러 날("2026.10.03 ~ 2026.10.04")이면 "~" 뒤에서 줄바꿈해서
  // 두 줄 다 각자 폭에 맞는 밑줄이 그려지는지 확인.
  testWidgets('공연 기간이 여러 날이면 물결표 뒤에서 줄바꿈된다', (tester) async {
    final news = NewsModel(
      artist: '아티스트',
      concert: '테스트 공연 [페스티벌]',
      imageUrl: '',
      description: '',
      venue: '서울 공연장',
      periodText: '2026.10.03 ~ 2026.10.04',
      concertDate: DateTime(2026, 10, 3),
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

    expect(find.text('2026.10.03 ~'), findsOneWidget);
    expect(find.text('2026.10.04'), findsOneWidget);
  });

  // [백엔드 수정]
  // 괄호가 중첩("파라다이스시티 (컬처파크 (야외))")돼도 바깥쪽 괄호 앞에서
  // 통째로 줄바꿈되는지 확인 - 예전 정규식은 중첩 괄호에서 매칭 자체가 안 됐음.
  testWidgets('공연장 옛 이름 괄호가 중첩돼도 바깥 괄호 앞에서 줄바꿈된다', (tester) async {
    final news = NewsModel(
      artist: '아티스트',
      concert: '테스트 공연 [페스티벌]',
      imageUrl: '',
      description: '',
      venue: '파라다이스시티 (컬처파크 (야외))',
      periodText: '2026.10.03 ~ 2026.10.04',
      concertDate: DateTime(2026, 10, 3),
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

    expect(find.text('파라다이스시티'), findsOneWidget);
    expect(find.text('(컬처파크 (야외))'), findsOneWidget);
  });
}
