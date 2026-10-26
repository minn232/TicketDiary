import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/artist_model.dart';
import 'package:ticketdiary/models/summary_report_data.dart';
import 'package:ticketdiary/services/artist_search_service.dart';
import 'package:ticketdiary/widgets/summary_report.dart';

class _Search implements ArtistSearchService {
  _Search({this.results = const []});
  final List<ArtistModel> results;
  final queries = <String>[];
  @override
  Future<List<ArtistModel>> search(String query) async {
    queries.add(query);
    return results;
  }
}

const _data = <String, dynamic>{
  'concert_count': 12,
  'total_spent': 1240000,
  'total_runtime_minutes': 1950,
  'runtime_missing_count': 2,
  'top_genres': ['뮤지컬', '콘서트'],
  'artists': [
    {'name': 'Artist B', 'count': 4},
    {'name': 'Artist A', 'count': 9},
    {'name': 'Artist A2', 'count': 9},
    {'name': 'Artist C', 'count': 1},
    {'name': 'Artist D', 'count': 1},
  ],
  'monthly_stats': [
    {'month': '2025-12', 'concert_count': 3, 'spent': 320000},
    {'month': '2026-01', 'concert_count': 2, 'spent': 120000},
  ],
  'song_count': 99,
  'photo_count': 55,
  'avg_ticket_price': 12345,
};

Future<void> _pump(
  WidgetTester tester, {
  double width = 340,
  double height = 800,
  Map<String, dynamic> data = _data,
  String period = '6m',
  _Search? search,
  Map<String, String>? selection,
}) async {
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFFF4F3F6),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: SummaryReport(
            key: UniqueKey(),
            data: data,
            period: period,
            initialPage: 0,
            onPageChanged: (_) {},
            yearSelection: selection ?? {},
            artistSearch: search ?? _Search(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final period in ['6m', '1y', 'all']) {
    testWidgets('$period without attendance shows only registration guidance', (
      tester,
    ) async {
      final search = _Search();
      await _pump(
        tester,
        period: period,
        search: search,
        data: {..._data, 'concert_count': 0},
      );
      expect(find.text('관람한 티켓을 등록하여 주세요'), findsOneWidget);
      expect(find.byType(PageView), findsNothing);
      expect(find.byTooltip('다음 보고서'), findsNothing);
      expect(find.text('관람한 공연'), findsNothing);
      expect(find.text('월별 지출 금액'), findsNothing);
      expect(search.queries, isEmpty);
      expect(tester.takeException(), isNull);
    });

    for (final size in [const Size(280, 420), const Size(390, 800)]) {
      testWidgets(
        '$period pages fill equal bounds without vertical scrolling at $size',
        (tester) async {
          await _pump(
            tester,
            width: size.width,
            height: size.height,
            period: period,
          );
          final firstPage = tester.getRect(
            find.byKey(const ValueKey('report-page-1')),
          );
          final firstBottom = tester
              .getRect(find.byKey(const ValueKey('spending-card')))
              .bottom;
          expect(find.byType(SingleChildScrollView), findsNothing);
          expect(
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position
                .axis,
            Axis.horizontal,
          );
          await tester.drag(
            find.byKey(const ValueKey('spending-chart')),
            const Offset(0, -150),
          );
          await tester.pumpAndSettle();
          expect(
            tester.getRect(find.byKey(const ValueKey('spending-card'))).bottom,
            firstBottom,
          );
          await tester.tap(find.byTooltip('다음 보고서'));
          await tester.pumpAndSettle();
          final secondPage = tester.getRect(
            find.byKey(const ValueKey('report-page-2')),
          );
          final secondBottom = tester
              .getRect(find.byKey(const ValueKey('artist-podium')))
              .bottom;
          expect(secondPage.top, closeTo(firstPage.top, .01));
          expect(secondPage.height, closeTo(firstPage.height, .01));
          expect(secondBottom, closeTo(firstBottom, .01));
          expect(
            secondBottom,
            lessThan(tester.getRect(find.byTooltip('다음 보고서')).top),
          );
          expect(find.byType(SingleChildScrollView), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('tapping a tied profile cycles its name and image, then wraps', (
    tester,
  ) async {
    final search = _Search(
      results: const [
        ArtistModel(
          name: '200',
          profileImageUrl: 'https://example.test/200.jpg',
        ),
        ArtistModel(
          name: 'NY team',
          profileImageUrl: 'https://example.test/ny.jpg',
        ),
      ],
    );
    await _pump(
      tester,
      search: search,
      data: {
        'concert_count': 5,
        'artists': [
          {'name': '200', 'count': 3},
          {'name': 'NY team', 'count': 3},
          {'name': 'Solo', 'count': 1},
        ],
      },
    );
    await tester.tap(find.byTooltip('다음 보고서'));
    await tester.pumpAndSettle();
    final profile = find.byKey(const ValueKey('artist-circle-1'));
    final bounds = tester.getRect(profile);
    String imageUrl() => tester
        .widget<CachedNetworkImage>(
          find.descendant(
            of: profile,
            matching: find.byType(CachedNetworkImage),
          ),
        )
        .imageUrl;
    expect(find.text('200 외 1명'), findsOneWidget);
    expect(imageUrl(), 'https://example.test/200.jpg');
    await tester.tap(profile);
    await tester.pumpAndSettle();
    expect(find.text('NY team 외 1명'), findsOneWidget);
    expect(find.text('200 외 1명'), findsNothing);
    expect(imageUrl(), 'https://example.test/ny.jpg');
    expect(tester.getRect(profile), bounds);
    expect(find.text('Solo'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('artist-circle-2')));
    await tester.pumpAndSettle();
    expect(find.text('Solo'), findsOneWidget);
    await tester.tap(find.byTooltip('이전 보고서'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('다음 보고서'));
    await tester.pumpAndSettle();
    expect(find.text('NY team 외 1명'), findsOneWidget);
    await tester.tap(profile);
    await tester.pumpAndSettle();
    expect(find.text('200 외 1명'), findsOneWidget);
    expect(imageUrl(), 'https://example.test/200.jpg');
    expect(search.queries.where((name) => name == '200').length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'portraits use the matching artist instead of a fuzzy first result',
    (tester) async {
      await _pump(
        tester,
        data: {
          'concert_count': 2,
          'artists': [
            {'name': 'Solo', 'count': 2},
          ],
        },
        search: _Search(
          results: const [
            ArtistModel(
              name: 'Solo Band',
              profileImageUrl: 'https://example.test/wrong.jpg',
            ),
            ArtistModel(
              name: 'Solo',
              profileImageUrl: 'https://example.test/solo.jpg',
            ),
          ],
        ),
      );
      await tester.tap(find.byTooltip('다음 보고서'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .imageUrl,
        'https://example.test/solo.jpg',
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('six months cross years, fill gaps, exclude old and future months', () {
    final months = reportMonths(
      {
        ..._data,
        'monthly_stats': [
          ..._data['monthly_stats'] as List,
          {'month': '2026-04', 'concert_count': 9, 'spent': 999},
        ],
      },
      '6m',
      now: DateTime(2026, 3, 15),
    );
    expect(months.map((m) => m.key), [
      '2025-10',
      '2025-11',
      '2025-12',
      '2026-01',
      '2026-02',
      '2026-03',
    ]);
    expect(months.map((m) => m.count), [0, 0, 3, 2, 0, 0]);
    expect(months.map((m) => m.spent), [0, 0, 320000, 120000, 0, 0]);
    expect(reportMonths({}, '1y', now: DateTime(2026, 3)).length, 12);
    expect(reportMonths({}, '6m', now: DateTime(2026, 3)).length, 6);
  });

  test(
    'ties form three count groups, stable representative, no fourth rank',
    () {
      final groups = reportArtistGroups({
        ..._data,
        'artists': [
          ..._data['artists'] as List,
          {'name': 'Zero', 'count': 0},
        ],
      });
      expect(groups.map((g) => g.count), [9, 4, 1]);
      expect(groups.map((g) => g.label), [
        'Artist A 외 1명',
        'Artist B',
        'Artist C 외 1명',
      ]);
    },
  );

  for (final width in [280.0, 390.0, 800.0]) {
    testWidgets(
      'four metrics, two pages, proportional nonoverlapping podium at $width',
      (tester) async {
        final search = _Search();
        await _pump(tester, width: width, search: search);
        expect(find.text('관람한 공연'), findsOneWidget);
        expect(find.text('총 관람 시간'), findsOneWidget);
        expect(find.text('32시간 30분'), findsOneWidget);
        expect(find.text('1,240,000원'), findsOneWidget);
        expect(find.text('선호 장르'), findsOneWidget);
        final a = tester.getRect(find.byKey(const ValueKey('metric-관람한 공연')));
        final b = tester.getRect(find.byKey(const ValueKey('metric-총 관람 시간')));
        final c = tester.getRect(find.byKey(const ValueKey('metric-총 지출 금액')));
        expect(a.top, b.top);
        expect(a.right, lessThan(b.left));
        expect(c.top, greaterThan(a.bottom));
        for (final label in [
          '들은 곡',
          '남긴 사진',
          '예매처 비중',
          '티켓 가격 비교',
          '처음 본 아티스트',
        ]) {
          expect(find.text(label), findsNothing);
        }
        await tester.tap(find.byTooltip('다음 보고서'));
        await tester.pumpAndSettle();
        expect(find.text('2 / 2'), findsOneWidget);
        expect(find.text('월별 관람 횟수'), findsOneWidget);
        final first = tester.getRect(
          find.byKey(const ValueKey('artist-circle-1')),
        );
        final second = tester.getRect(
          find.byKey(const ValueKey('artist-circle-2')),
        );
        final third = tester.getRect(
          find.byKey(const ValueKey('artist-circle-3')),
        );
        expect(second.right, lessThan(first.left));
        expect(first.right, lessThan(third.left));
        expect(first.width / second.width, closeTo(1.5, .001));
        expect(first.width / third.width, closeTo(3, .001));
        expect(find.text('Artist A 외 1명'), findsOneWidget);
        expect(search.queries.toSet(), {'Artist A', 'Artist B', 'Artist C'});
        await tester.tap(find.byTooltip('다음 보고서'));
        await tester.pumpAndSettle();
        expect(find.text('1 / 2'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('empty and partial data show zero charts and safe placeholders', (
    tester,
  ) async {
    await _pump(tester, data: {'concert_count': 1, 'runtime_missing_count': 3});
    expect(find.text('정보 없음'), findsOneWidget);
    expect(find.text('0원'), findsOneWidget);
    await tester.tap(find.byTooltip('다음 보고서'));
    await tester.pumpAndSettle();
    expect(find.text('관람 아티스트가 없어요'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _pump(
      tester,
      data: {
        'concert_count': 1,
        'artists': [
          {'name': 'Solo', 'count': 1},
        ],
      },
    );
    await tester.tap(find.byTooltip('이전 보고서'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('artist-circle-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('artist-circle-2')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all-period charts preserve independent year selections', (
    tester,
  ) async {
    final selection = <String, String>{'spent': '2025', 'count': '2026'};
    await _pump(tester, period: 'all', selection: selection);
    expect(
      tester
          .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
          .value,
      2025,
    );
    await tester.tap(find.byTooltip('다음 보고서'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
          .value,
      2026,
    );
    expect(tester.takeException(), isNull);
  });
}
