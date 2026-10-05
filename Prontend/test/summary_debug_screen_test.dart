import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/screen/summary_debug_screen.dart';

const _sample = <String, dynamic>{
  'concert_count': 12,
  'total_spent': 1280000,
  'avg_ticket_price': 106666,
  'top_genres': ['록/밴드', '발라드'],
  'total_runtime_minutes': 1560,
  'runtime_missing_count': 2,
  'song_count': 96,
  'song_count_estimated': 40,
  'photo_count': 31,
  'diary_count': 5,
  'monthly_stats': [
    {'month': '2025-11', 'concert_count': 1, 'spent': 99000},
    {'month': '2025-12', 'concert_count': 3, 'spent': 330000},
    {'month': '2026-01', 'concert_count': 0, 'spent': 0},
    {'month': '2026-02', 'concert_count': 2, 'spent': 180000},
    {'month': '2026-03', 'concert_count': 1, 'spent': 110000},
    {'month': '2026-04', 'concert_count': 2, 'spent': 240000},
    {'month': '2026-05', 'concert_count': 0, 'spent': 0},
    {'month': '2026-06', 'concert_count': 1, 'spent': 99000},
    {'month': '2026-07', 'concert_count': 2, 'spent': 222000},
  ],
  'weekday_counts': [0, 1, 1, 0, 2, 6, 2],
  'standing_percent': 67,
  'seated_percent': 33,
  'first_day_percent': 40,
  'last_day_percent': 60,
  'origin_domestic_percent': 58,
  'origin_foreign_percent': 42,
  'origin_unknown_count': 1,
  'ticketing_sites': [
    {'name': 'INTERPARK', 'count': 6, 'percent': 55},
    {'name': 'YES24', 'count': 3, 'percent': 27},
    {'name': '멜론티켓', 'count': 2, 'percent': 18},
  ],
  'ticketing_site_unknown_count': 1,
  'top_venues': [
    {'name': '올림픽공원 (KSPO DOME)', 'count': 4},
    {'name': '예스24 라이브홀', 'count': 3},
    {'name': '무신사 개러지', 'count': 2},
  ],
  'artists': [
    {'name': 'Vaundy', 'count': 3},
    {'name': 'YOASOBI', 'count': 2},
    {'name': '장기하', 'count': 1},
  ],
  'max_spend': {'concert_name': 'Vaundy ASIA ARENA TOUR', 'price': 165000},
  'busiest_month': {'month': '2025-12', 'count': 3},
  'top_spend_artist': {'name': 'Vaundy', 'amount': 330000},
  'most_heard_song': {'name': 'Hit Song', 'artist': 'Vaundy', 'count': 3},
  'rarest_song': {
    'name': 'Deep Cut',
    'artist': 'YOASOBI',
    'concert_name': 'YOASOBI ASIA TOUR',
    'probability': 0.0,
  },
  'new_artist_count': 2,
  'new_artists': ['Vaundy', 'YOASOBI'],
  'new_artists_by_year': [
    {
      'year': 2025,
      'artists': ['Vaundy'],
    },
    {
      'year': 2026,
      'artists': ['YOASOBI', 'Yuuri'],
    },
  ],
};

// width: 논리 폭(dp). 좁으면 페이지 높이가 모자라 스크롤 모드, 넓으면 카드가 높이를 꽉 채우는 모드
Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> data, {
  double width = 400,
}) async {
  tester.view.physicalSize = Size(width * 2, 6000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: SummaryDebugScreen(key: UniqueKey(), loader: (_) async => data),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 스크롤 모드에서만 아래 카드로 스크롤(꽉 채우는 모드는 이미 다 보임)
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    if (find.byType(ListView).evaluate().isEmpty) return;
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }

  Future<void> swipeLeft(WidgetTester tester) async {
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
  }

  for (final width in [400.0, 800.0]) {
    final mode = width < 600 ? '스크롤 모드' : '꽉 채우는 모드';

    testWidgets('3페이지로 나눠 그래프를 그린다($mode)', (tester) async {
      await _pump(tester, _sample, width: width);
      // 1페이지: 요약 / 기록 / 선호 비율(도넛)
      expect(find.text('106,000원'), findsOneWidget);
      expect(find.text('기록'), findsOneWidget);
      await scrollTo(tester, find.text('선호 비율'));
      expect(find.text('Hit Song'), findsOneWidget);
      expect(find.text('첫콘 40%'), findsOneWidget);
      expect(find.text('스탠딩 67%'), findsOneWidget);

      // 2페이지: 월별 관람/지출(연도 칩), 요일별
      await swipeLeft(tester);
      expect(find.text('월별 관람 수'), findsOneWidget);
      expect(find.text('33만'), findsNothing); // 2025년 12월 지출은 아직 안 보임
      await tester.tap(find.text('2025').first);
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('월별 지출'));
      await tester.tap(find.text('2025').last);
      await tester.pumpAndSettle();
      expect(find.text('33만'), findsOneWidget);
      await scrollTo(tester, find.text('요일별 공연 수'));
      expect(find.text('토'), findsOneWidget);

      // 3페이지: 예매처 / 공연장 / 아티스트 / 처음 본 아티스트
      await swipeLeft(tester);
      expect(find.text('예매처 비중'), findsOneWidget);
      expect(find.text('INTERPARK'), findsWidgets);
      await scrollTo(tester, find.text('해마다 처음 본 아티스트'));
      expect(find.text('가장 많이 간 공연장'), findsOneWidget);
      // 가장 최근 해가 기본 선택, 2025 칩을 누르면 그 해에 처음 본 아티스트가 보임
      expect(find.text('Yuuri'), findsOneWidget);
      // 스크롤 모드에서는 3페이지 목록 안의 칩을, 꽉 채우는 모드에서는 마지막 칩을 누름
      final chip = find.byType(ListView).evaluate().isEmpty
          ? find.text('2025').last
          : find
                .descendant(
                  of: find.byType(ListView).last,
                  matching: find.text('2025'),
                )
                .last;
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text('Yuuri'), findsNothing);
      expect(find.text('Vaundy'), findsWidgets);
      // 순환: 3페이지에서 왼쪽으로 넘기면 1페이지, 1페이지에서 오른쪽으로 넘기면 다시 3페이지
      await swipeLeft(tester);
      expect(find.text('106,000원'), findsOneWidget);
      await tester.fling(find.byType(PageView), const Offset(300, 0), 1500);
      await tester.pumpAndSettle();
      expect(find.text('예매처 비중'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('기간 버튼 하나를 누를 때마다 6개월, 1년, 전체 순으로 바뀐다', (tester) async {
    final requested = <String>[];
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: SummaryDebugScreen(
          loader: (period) async {
            requested.add(period);
            return _sample;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('전체'), findsOneWidget);
    for (final label in ['6개월', '1년', '전체']) {
      await tester.tap(find.byType(InkWell).last);
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
    }
    expect(requested, ['all', '6m', '1y', 'all']);
  });

  testWidgets('기간을 바꿔도 보던 페이지에 머문다', (tester) async {
    await _pump(tester, _sample, width: 800);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('월별 관람 수'), findsOneWidget); // 2페이지
    await tester.tap(find.byType(InkWell).last); // 기간 변경 -> 다시 불러옴
    await tester.pumpAndSettle();
    expect(find.text('월별 관람 수'), findsOneWidget); // 여전히 2페이지
    expect(find.text('106,000원'), findsNothing); // 1페이지로 돌아가지 않음
  });

  testWidgets('페이지를 한 바퀴 돌아와도 연도 칩 선택이 유지된다', (tester) async {
    bool selected(Finder chip) => tester.widget<ChoiceChip>(chip).selected;
    Finder chips() => find.widgetWithText(ChoiceChip, '2025').hitTestable();

    await _pump(tester, _sample, width: 800);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(selected(chips().first), isFalse); // 기본은 가장 최근 해(2026)
    await tester.tap(chips().first); // 월별 관람 수 카드: 2025 선택
    await tester.pumpAndSettle();
    expect(selected(chips().first), isTrue);

    // 2 -> 3 -> 1 -> 2페이지로 한 바퀴 돌아옴(그 사이 2페이지는 화면에서 사라져 새로 만들어짐)
    for (var i = 0; i < 3; i++) {
      await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
      await tester.pumpAndSettle();
    }
    expect(find.text('월별 관람 수'), findsOneWidget);
    expect(selected(chips().first), isTrue); // 관람 수 카드는 2025 유지
    expect(selected(chips().last), isFalse); // 지출 카드는 선택 안 했으니 그대로
  });

  testWidgets('6개월/1년에서는 기간 기준 처음 본 아티스트 카드를 보여준다', (tester) async {
    tester.view.physicalSize = const Size(1600, 6000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(home: SummaryDebugScreen(loader: (_) async => _sample)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(InkWell).last); // 전체 -> 6개월
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('처음 본 아티스트 2명'), findsOneWidget);
    expect(find.text('해마다 처음 본 아티스트'), findsNothing);
  });

  // 첫 로딩은 바로 돌려주고, 이후 요청은 기간별 Completer로 직접 완료시킴
  ({
    SummaryJsonLoader loader,
    Map<String, Completer<Map<String, dynamic>>> pending,
  })
  controlledLoader() {
    final pending = <String, Completer<Map<String, dynamic>>>{};
    var first = true;
    return (
      loader: (period) {
        if (first) {
          first = false;
          return Future.value(_sample);
        }
        final completer = Completer<Map<String, dynamic>>();
        pending[period] = completer;
        return completer.future;
      },
      pending: pending,
    );
  }

  Future<void> pumpControlled(
    WidgetTester tester,
    SummaryJsonLoader loader,
  ) async {
    tester.view.physicalSize = const Size(1600, 6000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(home: SummaryDebugScreen(loader: loader)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('기간을 바꾸는 동안 이전 내용을 그대로 두고 값만 교체한다', (tester) async {
    final c = controlledLoader();
    await pumpControlled(tester, c.loader);
    expect(find.text('106,000원'), findsOneWidget);

    await tester.tap(find.byType(InkWell).last); // 전체 -> 6개월
    await tester.pump();
    // 불러오는 중: 이전 값이 그대로 보이고, 위쪽 진행 막대만 나타남
    expect(find.text('106,000원'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('6개월'), findsOneWidget);

    c.pending['6m']!.complete({..._sample, 'avg_ticket_price': 200000});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('200,000원'), findsOneWidget);
    expect(find.text('106,000원'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('연달아 눌러도 마지막 요청의 결과만 반영한다', (tester) async {
    final c = controlledLoader();
    await pumpControlled(tester, c.loader);
    await tester.tap(find.byType(InkWell).last); // 6개월 요청
    await tester.pump();
    await tester.tap(find.byType(InkWell).last); // 1년 요청
    await tester.pump();

    c.pending['1y']!.complete({..._sample, 'avg_ticket_price': 200000});
    await tester.pump();
    c.pending['6m']!.complete({
      ..._sample,
      'avg_ticket_price': 300000,
    }); // 늦게 온 이전 응답
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('200,000원'), findsOneWidget);
    expect(find.text('300,000원'), findsNothing);
    expect(find.text('1년'), findsOneWidget);
  });

  testWidgets('새 값을 못 불러오면 이전 값과 이전 기간을 유지하고 안내만 띄운다', (tester) async {
    final c = controlledLoader();
    await pumpControlled(tester, c.loader);
    await tester.tap(find.byType(InkWell).last);
    await tester.pump();
    c.pending['6m']!.completeError(Exception('network'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('106,000원'), findsOneWidget); // 이전 값 유지
    expect(find.text('전체'), findsOneWidget); // 버튼도 이전 기간으로 복귀
    expect(find.textContaining('불러오지 못했어요'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4)); // 안내가 사라짐
    expect(find.textContaining('불러오지 못했어요'), findsNothing);
  });

  testWidgets('값이 없는 기록 타일은 숨기고, 하나도 없으면 카드째 숨긴다', (tester) async {
    final onlySpend = {
      ..._sample,
      'top_spend_artist': null,
      'most_heard_song': null,
      'rarest_song': null,
    };
    await _pump(tester, onlySpend, width: 800);
    expect(find.text('기록'), findsOneWidget);
    expect(find.text('최고 지출'), findsOneWidget);
    expect(find.text('가장 많이 들은 곡'), findsNothing);
    expect(find.text('가장 희귀한 곡'), findsNothing);

    final none = {...onlySpend, 'max_spend': null};
    await _pump(tester, none, width: 800);
    expect(find.text('기록'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('빈 응답도 깨지지 않는다', (tester) async {
    for (final width in [400.0, 800.0]) {
      await _pump(tester, const {
        'monthly_stats': [],
        'weekday_counts': [0, 0, 0, 0, 0, 0, 0],
        'artists': [],
      }, width: width);
      expect(tester.takeException(), isNull);
      expect(find.text('-'), findsWidgets);
    }
  });
}
