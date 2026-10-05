import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/summary_map.dart';
import 'package:ticketdiary/models/summary_map_drawing.dart';
import 'package:ticketdiary/widgets/summary_region_map.dart';
import 'package:ticketdiary/screen/summary_screen.dart';
import 'package:ticketdiary/services/summary_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SummaryMapData data;
  setUpAll(() async {
    data = SummaryMapData.parse(
      await File('assets/maps/korea.json').readAsString(),
    );
  });
  test('provinces have subdivisions and interior label anchors', () {
    expect(data.children(null).length, greaterThanOrEqualTo(16));
    for (final province in data.children(null)) {
      expect(data.children(province.id), isNotEmpty, reason: province.name);
      expect(province.contains(province.anchor), isTrue, reason: province.name);
    }
    expect(data.children('11').length, 25);
    expect(data.children('36').any((r) => r.name.endsWith('면')), isTrue);
  });
  test('coordinates count in district and parent once; sea excluded', () {
    final counts = data.countVisits(const [
      SummaryMapVisit(Offset(127.1273, 37.5209), 3),
      SummaryMapVisit(Offset(126.9784, 37.5666), 2),
      SummaryMapVisit(Offset(130, 34), 9),
    ]);
    expect(counts['11'], 5);
    expect(counts['11710'], 3);
    expect(counts['11140'], 2);
    expect(counts.values.fold<int>(0, (a, b) => a + b), 10);
  });
  test('projected anchors hit correct regions at phone and tablet sizes', () {
    for (final size in [const Size(300, 460), const Size(680, 760)]) {
      for (final parent in <String?>[
        null,
        ...data.children(null).map((r) => r.id),
      ]) {
        final regions = data.children(parent);
        final layout = SummaryMapLayout(regions, size);
        for (final region in regions) {
          expect(
            layout.hitTest(layout.anchors[region.id]!),
            region.id,
            reason: region.name,
          );
        }
        expect(layout.hitTest(Offset.zero), isNull);
        final bounds = layout.paths.values
            .map((p) => p.getBounds())
            .reduce((a, b) => a.expandToInclude(b));
        expect(bounds.width, lessThanOrEqualTo(size.width));
        expect(bounds.height, lessThanOrEqualTo(size.height));
        final rings = SummaryMapDrawing.polygons(
          regions,
          viewport: size,
        ).values.expand((p) => p);
        final original = Path();
        for (final ring in rings) {
          original.addPolygon(ring, true);
        }
        final originalBounds = original.getBounds();
        expect(
          bounds.width / bounds.height,
          closeTo(originalBounds.width / originalBounds.height, .0001),
        );
      }
    }
  });
  test('small offshore polygons do not shrink the mainland viewport', () {
    List<Offset> square(double x, double y, double side) => [
      Offset(x, y),
      Offset(x + side, y),
      Offset(x + side, y + side),
      Offset(x, y + side),
      Offset(x, y),
    ];
    final mainland = SummaryMapRegion(
      id: 'main',
      name: '본토',
      anchor: const Offset(127.5, 36.5),
      polygons: [
        [square(127, 36, 1)],
        [square(120, 36, .3)],
      ],
    );
    final islandRegion = SummaryMapRegion(
      id: 'island',
      name: '독립 도서 지역',
      anchor: const Offset(127.6, 35.6),
      polygons: [
        [square(127.5, 35.5, .2)],
      ],
    );
    final drawing = SummaryMapDrawing.polygons([mainland, islandRegion]);
    expect(drawing['main']!.length, 1);
    expect(drawing['island']!.length, 1);
    final layout = SummaryMapLayout([
      mainland,
      islandRegion,
    ], const Size(300, 460));
    final baseline = SummaryMapLayout([
      SummaryMapRegion(
        id: mainland.id,
        name: mainland.name,
        anchor: mainland.anchor,
        polygons: [mainland.polygons.first],
      ),
      islandRegion,
    ], const Size(300, 460));
    expect(
      layout.paths['main']!.getBounds().width,
      closeTo(baseline.paths['main']!.getBounds().width, .0001),
    );
    expect(layout.hitTest(layout.anchors['island']!), 'island');
  });
  testWidgets(
    'province fade, district bubble and pinch returns directly to national',
    (tester) async {
      tester.view.physicalSize = const Size(390, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final loader = FontLoader('NanumGalmaesgeul')
          ..addFont(rootBundle.load('assets/fonts/NanumGalmaesgeul.ttf'));
        await loader.load();
      });
      final boundary = GlobalKey();
      final state = GlobalKey<SummaryRegionMapState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'NanumGalmaesgeul'),
          home: Scaffold(
            backgroundColor: const Color(0xFFCEB99B),
            body: RepaintBoundary(
              key: boundary,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: SummaryRegionMap(
                  key: state,
                  data: data,
                  counts: const {'11710': 3},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        if (Platform.environment['SUMMARY_MAP_SCREENSHOTS'] != '1') return;
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/tmp/ticketdiary-map/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      Finder painter() => find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_RegionPainter',
      );
      Future<void> tapRegion(String? parent, String id) async {
        final box = tester.renderObject<RenderBox>(painter());
        final layout = SummaryMapLayout(data.children(parent), box.size);
        await tester.tapAt(box.localToGlobal(layout.anchors[id]!));
        await tester.pumpAndSettle();
      }

      await capture('national');
      await tapRegion(null, '11');
      expect(find.text('서울특별시'), findsOneWidget);
      expect(state.currentState!.canGoBack, isTrue);
      await tapRegion('11', '11710');
      expect(find.text('공연 3회 관람'), findsOneWidget);
      await capture('seoul');
      final box = tester.renderObject<RenderBox>(painter());
      await tester.tapAt(box.localToGlobal(const Offset(2, 2)));
      await tester.pumpAndSettle();
      expect(find.text('공연 3회 관람'), findsNothing);
      expect(find.text('서울특별시'), findsOneWidget);
      // Outside taps only dismiss the bubble; two fingers pinching return home.
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      final center = box.localToGlobal(box.size.center(Offset.zero));
      final left = await tester.startGesture(
        center - const Offset(80, 0),
        pointer: 1,
      );
      final right = await tester.startGesture(
        center + const Offset(80, 0),
        pointer: 2,
      );
      await tester.pump();
      await left.moveTo(center - const Offset(60, 0));
      await right.moveTo(center + const Offset(60, 0));
      await tester.pump();
      await left.moveTo(center - const Offset(25, 0));
      await right.moveTo(center + const Offset(25, 0));
      await tester.pump();
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      expect(find.text('나의 관람 지도'), findsOneWidget);
      expect(state.currentState!.canGoBack, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'full page period changes ignore stale data and recover from errors',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await SummaryMapData.load();
        final font = FontLoader('NanumGalmaesgeul')
          ..addFont(rootBundle.load('assets/fonts/NanumGalmaesgeul.ttf'));
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      final service = _ControlledSummaryService();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'NanumGalmaesgeul'),
          home: RepaintBoundary(
            key: boundary,
            child: SummaryScreen(service: service),
          ),
        ),
      );
      // The cached asset future completed in runAsync's real event loop.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(service.requested, ['all']);
      await tester.tap(find.text('6개월'));
      await tester.pump();
      expect(service.requested, ['all', '6m']);
      service.pending['all']!.complete(
        const RegionalSummary(visits: [], total: 99, unresolved: 99),
      );
      await tester.pump();
      expect(find.textContaining('99회'), findsNothing);
      service.reports['6m']!.complete(_report(6));
      service.pending['6m']!.complete(
        const RegionalSummary(visits: [], total: 0, unresolved: 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('6개월 결산 보고서'), findsOneWidget);
      expect(find.text('관람 기록을 다시 불러오기'), findsNothing);
      expect(find.textContaining('SGIS'), findsNothing);
      if (Platform.environment['SUMMARY_MAP_SCREENSHOTS'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/tmp/ticketdiary-map/full-page.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final handle = find.byKey(const ValueKey('summary-report-handle'));
      await tester.drag(handle, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.text('총 지출 금액').hitTestable(), findsOneWidget);
      expect(find.text('6회').hitTestable(), findsOneWidget);
      if (Platform.environment['SUMMARY_MAP_SCREENSHOTS'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/tmp/ticketdiary-map/report.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('1년'));
      await tester.pump();
      service.pending['1y']!.completeError(Exception('offline'));
      service.reports['1y']!.completeError(Exception('offline'));
      await tester.pumpAndSettle();
      expect(find.text('관람 기록을 다시 불러오기'), findsNothing);
      expect(find.text('1년 결산 보고서'), findsOneWidget);
      await tester.tap(find.text('1년'));
      await tester.pump();
      service.reports['1y']!.complete(_report(1));
      service.pending['1y']!.complete(
        const RegionalSummary(visits: [], total: 0, unresolved: 0),
      );
      await tester.pumpAndSettle();
      await tester.drag(handle, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.text('1회').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _ControlledSummaryService extends SummaryService {
  final requested = <String>[];
  final pending = <String, Completer<RegionalSummary>>{};
  final reports = <String, Completer<SummaryModel>>{};
  @override
  Future<SummaryModel> fetchSummary({String period = 'all'}) {
    final completer = Completer<SummaryModel>();
    reports[period] = completer;
    return completer.future;
  }

  @override
  Future<RegionalSummary> fetchRegions({String period = 'all'}) {
    requested.add(period);
    final completer = Completer<RegionalSummary>();
    pending[period] = completer;
    return completer.future;
  }
}

SummaryModel _report(int count) => SummaryModel(
  concertCount: count,
  totalSpending: 150000,
  songCount: 25,
  favoriteGenre: '록',
  visitedArtists: [],
  standingRatio: .5,
  seatRatio: .5,
  firstConcertRatio: 0,
  lastConcertRatio: 1,
);
