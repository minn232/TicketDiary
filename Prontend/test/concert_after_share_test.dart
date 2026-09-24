import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/models/page_layout.dart';
import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/services/layout_config_service.dart';
import 'package:ticketdiary/services/scrapbook_auto_layout.dart';
import 'package:ticketdiary/widgets/concert_after_page_contents.dart';
import 'package:ticketdiary/widgets/concert_after_share_card.dart';
import 'package:ticketdiary/widgets/concert_after_share_sheet.dart';
import 'package:ticketdiary/widgets/setlist_music_service_control.dart';

/// 공연후 페이지 공유: 공유 버튼, 편집 UI 없는 미리보기, 보던 그대로의 배치, 카드 크기/캡처.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LayoutConfigService.debugSetWeights(const LayoutWeights(iterations: 300));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  Widget page(TicketInfo info, {double height = 500}) => MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: height,
            child: ConcertAfterPageContents(
              concertTitle: '테스트 공연',
              ticketInfo: info,
            ),
          ),
        ),
      ),
    ),
  );

  const memo = PageLayoutItem(
    id: 'text_m1',
    type: PageLayoutItemType.text,
    ref: 'm1',
    text: '최고의 밤',
    cx: 0.55,
    cy: 0.8,
    w: 0.3,
  );

  TicketInfo info({double aspect = 1.25}) => TicketInfo(
    concertName: '테스트 공연',
    venueName: '올림픽홀',
    date: DateTime(2026, 9, 20),
    pageLayout: PageLayout(canvasAspect: aspect, items: const [memo]),
  );

  final shareButton = find.byKey(const ValueKey('after_share_button'));
  Finder inSheet(Finder f) =>
      find.descendant(of: find.byType(ConcertAfterShareSheet), matching: f);

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(shareButton);
    await tester.pumpAndSettle();
  }

  group('공유 버튼', () {
    testWidgets('잠금 모드에서만 자물쇠 옆에 보인다', (tester) async {
      await tester.pumpWidget(page(info()));
      await tester.pumpAndSettle();
      expect(shareButton, findsOneWidget);
      // 자물쇠 표시 오른쪽, 같은 줄.
      final lock = tester.getCenter(find.byIcon(Icons.lock_outline));
      final share = tester.getCenter(shareButton);
      expect(share.dx, greaterThan(lock.dx));
      expect((share.dy - lock.dy).abs(), lessThan(1));

      await tester.longPressAt(const Offset(30, 520));
      await tester.pumpAndSettle();
      expect(find.text('편집 모드'), findsOneWidget);
      expect(shareButton, findsNothing);
    });
  });

  group('공유 미리보기', () {
    testWidgets('편집 UI 없이 날짜·공연장 띠와 함께 앞면을 보여준다', (tester) async {
      await tester.pumpWidget(page(info()));
      await tester.pumpAndSettle();
      await openSheet(tester);

      expect(find.byType(ConcertAfterShareSheet), findsOneWidget);
      expect(inSheet(find.byType(ConcertAfterShareCard)), findsOneWidget);
      expect(inSheet(find.text('최고의 밤')), findsOneWidget);
      expect(inSheet(find.text('2026.09.20 · 올림픽홀')), findsOneWidget);
      expect(inSheet(find.text('TicketDiary')), findsOneWidget);
      expect(inSheet(find.byIcon(Icons.lock_outline)), findsNothing);
      expect(
        inSheet(find.byIcon(Icons.ios_share)),
        findsNothing,
        reason: '페이지 안 공유 버튼은 안 찍힘',
      );
      expect(inSheet(find.text('더블탭하여 입력')), findsNothing);
    });

    testWidgets('설치 안 된 앱 아이콘은 숨기고 저장/더보기만', (tester) async {
      await tester.pumpWidget(page(info()));
      await tester.pumpAndSettle();
      await openSheet(tester);
      expect(inSheet(find.text('사진첩 저장')), findsOneWidget);
      expect(inSheet(find.text('더보기')), findsOneWidget);
      for (final app in ['인스타그램', 'X', '카카오톡']) {
        expect(inSheet(find.text(app)), findsNothing, reason: app);
      }
      expect(
        inSheet(find.text('3:4')),
        findsNothing,
        reason: '카카오용 비율은 선택지에 없음',
      );
    });

    testWidgets('설치된 앱 아이콘, 인스타는 스토리/피드 카톡은 카드/사진 선택', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('ticketdiary/share_targets'),
            (call) async => call.method == 'installed'
                ? {'instagram': true, 'x': true, 'kakao': true}
                : true,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('ticketdiary/share_targets'),
              null,
            ),
      );
      await tester.pumpWidget(page(info()));
      await tester.pumpAndSettle();
      await openSheet(tester);
      for (final label in ['사진첩 저장', '인스타그램', 'X', '카카오톡', '더보기']) {
        expect(inSheet(find.text(label)), findsOneWidget, reason: label);
      }

      await tester.tap(inSheet(find.text('인스타그램')));
      await tester.pumpAndSettle();
      expect(find.text('스토리'), findsOneWidget);
      expect(find.text('피드'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(inSheet(find.text('카카오톡')));
      await tester.pumpAndSettle();
      expect(find.text('카드'), findsOneWidget);
      expect(find.text('사진'), findsOneWidget);
    });

    testWidgets('인스타 피드는 넘어가기 전에 비율 안내, 취소하면 안 보냄', (tester) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('ticketdiary/share_targets'),
            (call) async {
              calls.add(call.method);
              return call.method == 'installed'
                  ? {'instagram': true, 'x': false, 'kakao': false}
                  : true;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('ticketdiary/share_targets'),
              null,
            ),
      );
      await tester.pumpWidget(page(info()));
      await tester.pumpAndSettle();
      await openSheet(tester);
      await tester.tap(inSheet(find.text('인스타그램')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('피드'));
      await tester.pumpAndSettle();

      expect(find.text('인스타에서 비율을 바꿔주세요'), findsOneWidget);
      expect(find.text('다시 보지 않기'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(find.text('인스타에서 비율을 바꿔주세요'), findsNothing);
      expect(calls, isNot(contains('instagramFeed')));
    });

    testWidgets('뒷면은 음악앱/편집 아이콘 없이 그린다', (tester) async {
      await tester.pumpWidget(page(info()));
      await tester.pumpAndSettle();
      await openSheet(tester);
      await tester.tap(inSheet(find.text('뒷면')));
      await tester.pumpAndSettle();

      expect(inSheet(find.text('실제 셋 리스트')), findsWidgets);
      expect(inSheet(find.byType(SetlistServiceIcon)), findsNothing);
      expect(inSheet(find.byIcon(Icons.edit_outlined)), findsNothing);
    });

    testWidgets('앞+뒤를 고르면 카드 2장', (tester) async {
      await tester.pumpWidget(page(info()));
      await tester.pumpAndSettle();
      await openSheet(tester);
      await tester.tap(inSheet(find.text('앞+뒤')));
      await tester.pumpAndSettle();
      expect(inSheet(find.byType(ConcertAfterShareCard)), findsNWidgets(2));
    });

    testWidgets('자유메모 숨기기를 켜면 메모가 빠진다', (tester) async {
      await tester.pumpWidget(page(info()));
      await tester.pumpAndSettle();
      await openSheet(tester);
      expect(inSheet(find.text('최고의 밤')), findsOneWidget);

      await tester.tap(inSheet(find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('최고의 밤')), findsNothing);
      expect(find.text('최고의 밤'), findsOneWidget, reason: '원래 페이지는 그대로');
    });

    testWidgets('자유메모가 페이지 안 같은 비율 위치에 그려진다', (tester) async {
      await tester.pumpWidget(page(info()));
      await tester.pumpAndSettle();
      final pageRect = tester.getRect(find.byType(ConcertAfterPageContents));
      final live = tester.getCenter(find.text('최고의 밤'));
      final liveNorm = (live - pageRect.topLeft) / pageRect.width;

      await openSheet(tester);
      final card = tester.widget<ConcertAfterShareCard>(
        inSheet(find.byType(ConcertAfterShareCard)),
      );
      expect(card.pageSize, const Size(400, 500));
      final g = ShareCardGeometry.compute(card.pageSize, card.aspect);
      final cardRect = tester.getRect(
        inSheet(find.byType(ConcertAfterShareCard)),
      );
      final scale = cardRect.width / g.card.width;
      final pageOrigin = cardRect.topLeft + g.page.topLeft * scale;
      final shown = tester.getCenter(inSheet(find.text('최고의 밤')));
      final shownNorm = (shown - pageOrigin) / (g.page.width * scale);

      expect(shownNorm.dx, closeTo(liveNorm.dx, 0.005));
      expect(shownNorm.dy, closeTo(liveNorm.dy, 0.005));
    });

    testWidgets('화면이 기준보다 납작하면(태블릿 가로) 기준 비율 높이로 그린다', (tester) async {
      await tester.pumpWidget(page(info(aspect: 1.55), height: 400));
      await tester.pumpAndSettle();
      await openSheet(tester);
      final card = tester.widget<ConcertAfterShareCard>(
        inSheet(find.byType(ConcertAfterShareCard)),
      );
      expect(card.pageSize.width, 400);
      expect(card.pageSize.height, closeTo(620, 0.01));
    });
  });

  group('카드 크기', () {
    const pageSize = Size(360, 640);

    test('원본은 페이지 + 여백 + 정보 띠', () {
      final g = ShareCardGeometry.compute(pageSize, ShareCardAspect.original);
      expect(g.page.size, pageSize, reason: '페이지 크기는 안 바뀜');
      expect(g.band.top, g.page.bottom);
      expect(g.band.width, pageSize.width);
      expect(g.card.width, greaterThan(pageSize.width));
      expect(g.card.height, greaterThan(g.band.bottom));
    });

    for (final aspect in [
      ShareCardAspect.story,
      ShareCardAspect.feed,
      ShareCardAspect.kakao,
    ]) {
      test('${aspect.label}는 비율을 맞추고 페이지를 안에 둔다', () {
        for (final size in const [pageSize, Size(560, 700), Size(400, 1000)]) {
          final g = ShareCardGeometry.compute(size, aspect);
          expect(g.card.height / g.card.width, closeTo(aspect.ratio!, 1e-9));
          expect(g.page.size, size);
          final bounds = Offset.zero & g.card;
          expect(bounds.contains(g.page.topLeft), isTrue);
          expect(g.band.bottom, lessThanOrEqualTo(g.card.height + 1e-9));
          expect(g.page.center.dx, closeTo(g.card.width / 2, 1e-9));
        }
      });
    }

    testWidgets('스토리용 앞+뒤 합성: 두 면 모두 보이고 바깥은 투명', (tester) async {
      Future<Uint8List> solid(Color color) async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(color, BlendMode.src);
        final image = await recorder.endRecording().toImage(300, 600);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      }

      final (w, h, pixels) = (await tester.runAsync(() async {
        final png = await composeTiltedPairPng(
          await solid(const Color(0xFFFF0000)),
          await solid(const Color(0xFF0000FF)),
        );
        final out = Platform.environment['STORY_PAIR_OUT'];
        if (out != null) await File(out).writeAsBytes(png);
        final codec = await ui.instantiateImageCodec(png);
        final image = (await codec.getNextFrame()).image;
        final data = await image.toByteData();
        final result = (image.width, image.height, data!);
        image.dispose();
        return result;
      }))!;
      (int, int, int, int) at(double fx, double fy) {
        final i = ((fy * h).floor() * w + (fx * w).floor()) * 4;
        return (
          pixels.getUint8(i),
          pixels.getUint8(i + 1),
          pixels.getUint8(i + 2),
          pixels.getUint8(i + 3),
        );
      }

      expect(w, greaterThan(300 * 1.6), reason: '두 장이 옆으로 이어짐');
      expect(h, greaterThan(600 * 1.3), reason: '앞면이 아래로 내려감');
      expect(at(0.002, 0.002).$4, 0, reason: '모서리는 투명');
      expect(at(0.25, 0.7), (255, 0, 0, 255), reason: '앞면(빨강)이 왼쪽 아래');
      expect(at(0.75, 0.25), (0, 0, 255, 255), reason: '뒷면(파랑)이 오른쪽 위');
      expect(at(0.45, 0.6), (255, 0, 0, 255), reason: '겹친 곳은 앞면이 위');
    });

    testWidgets('캡처하면 폭 1080 PNG', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: FittedBox(
              child: RepaintBoundary(
                key: key,
                child: const ConcertAfterShareCard(
                  pageSize: Size(300, 500),
                  aspect: ShareCardAspect.story,
                  infoText: '2026.09.20 · 올림픽홀',
                  page: ColoredBox(color: Color(0xFFF4F1E1)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = (await tester.runAsync(() => captureShareCardPng(boundary)))!;
      final codec = (await tester.runAsync(
        () => ui.instantiateImageCodec(png),
      ))!;
      final frame = (await tester.runAsync(codec.getNextFrame))!;
      expect(frame.image.width, 1080);
      expect(frame.image.height, 1920);
      frame.image.dispose();
    });
  });
}
