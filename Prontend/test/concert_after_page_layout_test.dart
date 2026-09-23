import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ticketdiary/models/page_layout.dart';
import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/services/layout_config_service.dart';
import 'package:ticketdiary/services/scrapbook_auto_layout.dart';
import 'package:ticketdiary/widgets/app_network_image.dart';
import 'package:ticketdiary/widgets/setlist_editor_sheet.dart';
import 'package:ticketdiary/widgets/setlist_music_service_control.dart';
import 'package:ticketdiary/widgets/concert_after_page_contents.dart';

/// 공연후 페이지 배치를 page_layout(정규화 좌표)으로 불러오고 저장하는지 검증.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LayoutConfigService.debugSetWeights(const LayoutWeights(iterations: 300));
    // 사진 캐시(cached_network_image)가 runAsync 중 저장 폴더를 요청함 - 임시 폴더로 응답.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });

  // 편집 도구 버튼이 페이지 위쪽 바깥에 뜨므로 위 여백을 둠.
  Widget page(TicketInfo info) => MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.only(top: 80),
        child: SizedBox(
          width: 400,
          height: 500,
          child: ConcertAfterPageContents(
            concertTitle: '테스트 공연',
            ticketInfo: info,
          ),
        ),
      ),
    ),
  );

  PageLayoutItem photo(String id, double cx, double cy) => PageLayoutItem(
    id: id,
    type: PageLayoutItemType.photo,
    ref: 'https://example.com/$id.jpg',
    cx: cx,
    cy: cy,
    w: 0.3,
    photo: const PageLayoutPhoto(w: 1024, h: 768),
  );

  Set<String> shownPhotoUrls(WidgetTester tester) => tester
      .widgetList<AppNetworkImage>(find.byType(AppNetworkImage))
      .map((w) => w.url)
      .where((u) => u.contains('example.com'))
      .toSet();

  testWidgets('저장된 page_layout의 사진을 전부 보여준다', (tester) async {
    await tester.pumpWidget(
      page(
        TicketInfo(
          concertName: '테스트 공연',
          pageLayout: PageLayout(
            canvasAspect: 1.55,
            items: [photo('a', 0.3, 0.5), photo('b', 0.7, 0.9)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(shownPhotoUrls(tester), {
      'https://example.com/a.jpg',
      'https://example.com/b.jpg',
    });
  });

  testWidgets('배치가 없고 예전 concert_photo_urls 사진만 있으면 자동 배치해 캐시에 저장한다', (
    tester,
  ) async {
    await tester.pumpWidget(
      page(
        const TicketInfo(
          concertName: '테스트 공연',
          concertPhotoUrls: [
            'https://example.com/old1.jpg',
            'https://example.com/old2.jpg',
          ],
        ),
      ),
    );
    // 이미지 크기 확인 + 자동 배치(compute)가 실제 비동기로 돌도록.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getString(
              'concert_after_page_layout_v1_local_after_테스트 공연',
            ) !=
            null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(
      'concert_after_page_layout_v1_local_after_테스트 공연',
    );
    expect(raw, isNotNull);
    final saved = PageLayout.tryParse(jsonDecode(raw!))!;
    expect(saved.photos.map((p) => p.ref).toSet(), {
      'https://example.com/old1.jpg',
      'https://example.com/old2.jpg',
    });
    // 캔버스 폭 = 1 정규화 좌표, 제목 영역 아래.
    for (final p in saved.photos) {
      expect(p.cx, inInclusiveRange(0, 1));
      expect(p.w, inExclusiveRange(0, 1));
    }
    expect(shownPhotoUrls(tester).length, 2);
  });

  PageLayoutItem pinnedPhoto(String id, double cx, double cy) => PageLayoutItem(
    id: id,
    type: PageLayoutItemType.photo,
    ref: 'https://example.com/$id.jpg',
    cx: cx,
    cy: cy,
    w: 0.3,
    pinned: true,
    photo: const PageLayoutPhoto(w: 1024, h: 768),
  );

  Future<void> enterEditMode(WidgetTester tester) async {
    // 사진이 없는 아래쪽 빈 곳을 꾹 눌러 편집 모드로.
    await tester.longPressAt(const Offset(30, 560));
    await tester.pumpAndSettle();
  }

  Future<PageLayout?> cachedLayout(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('concert_after_page_layout_v1_$key');
    return raw == null ? null : PageLayout.tryParse(jsonDecode(raw));
  }

  testWidgets('편집 모드에서 사진마다 고정 배지가 보이고 누르면 고정/해제된다', (tester) async {
    await tester.pumpWidget(
      page(
        TicketInfo(
          concertName: '테스트 공연',
          pageLayout: PageLayout(
            canvasAspect: 1.55,
            items: [pinnedPhoto('a', 0.3, 0.5), photo('b', 0.7, 0.9)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.push_pin), findsNothing, reason: '잠금 모드에선 안 보임');

    await enterEditMode(tester);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.push_pin_outlined));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.push_pin), findsNWidgets(2));

    final saved = await cachedLayout('local_after_테스트 공연');
    expect(saved!.photos.every((p) => p.pinned), isTrue);
  });

  testWidgets('자유메모가 있으면 자동 배치 전에 확인하고, 취소하면 그대로 둔다', (tester) async {
    await tester.pumpWidget(
      page(
        TicketInfo(
          concertName: '테스트 공연',
          ticketId: 't1',
          review: '정말 좋았다',
          pageLayout: PageLayout(
            canvasAspect: 1.25,
            items: [pinnedPhoto('a', 0.3, 0.5), photo('b', 0.7, 0.9)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('정말 좋았다'), findsOneWidget);

    await enterEditMode(tester);
    await tester.tap(find.text('자동 배치'));
    await tester.pumpAndSettle();
    expect(find.text('자유메모가 지워져요'), findsOneWidget);

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(find.text('자유메모가 지워져요'), findsNothing);
    expect(find.text('정말 좋았다'), findsOneWidget);

    await tester.tap(find.text('자동 배치'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우고 배치'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        final saved = await cachedLayout('t1');
        if (saved != null &&
            saved.photos.any((p) => p.id == 'b' && p.cx != 0.7)) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();

    expect(find.text('정말 좋았다'), findsNothing);
    final saved = await cachedLayout('t1');
    final a = saved!.photos.firstWhere((p) => p.id == 'a');
    expect(a.pinned, isTrue);
    expect(a.cx, closeTo(0.3, 1e-6), reason: '고정된 사진은 자리 유지');
    expect(a.cy, closeTo(0.5, 1e-6));
    final b = saved.photos.firstWhere((p) => p.id == 'b');
    expect(b.cx == 0.7 && b.cy == 0.9, isFalse, reason: '고정 안 된 사진은 다시 배치');

    // 서버 저장 대기(0.6초 모아 보내기)와 네트워크 요청이 끝나도록 정리.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('page_layout의 자유메모를 같은 자리/크기로 복원하고 다시 저장한다', (tester) async {
    await tester.pumpWidget(
      page(
        TicketInfo(
          concertName: '테스트 공연',
          pageLayout: PageLayout(
            canvasAspect: 1.25,
            items: [
              photo('a', 0.3, 0.5),
              const PageLayoutItem(
                id: 'text_m1',
                type: PageLayoutItemType.text,
                ref: 'm1',
                text: '최고의 밤',
                cx: 0.55,
                cy: 1.0,
                w: 0.4,
                rot: 0.05,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('최고의 밤'), findsOneWidget);

    // 사진 고정을 바꿔서 저장을 한 번 일으킴.
    await enterEditMode(tester);
    await tester.tap(find.byIcon(Icons.push_pin_outlined));
    await tester.pumpAndSettle();

    final saved = await cachedLayout('local_after_테스트 공연');
    final memo = saved!.items.singleWhere(
      (i) => i.type == PageLayoutItemType.text,
    );
    expect(memo.text, '최고의 밤');
    expect(memo.ref, 'm1');
    expect(memo.cx, closeTo(0.55, 0.01));
    expect(memo.cy, closeTo(1.0, 0.01));
    expect(memo.w, closeTo(0.4, 0.01));
    expect(memo.rot, closeTo(0.05, 1e-6));
  });

  testWidgets('배치가 없는 페이지는 서버 후기로 만든 자유메모를 page_layout에 담는다', (tester) async {
    await tester.pumpWidget(
      page(const TicketInfo(concertName: '테스트 공연', review: '좋았다')),
    );
    await tester.pumpAndSettle();
    expect(find.text('좋았다'), findsOneWidget);

    // 포스터 고정을 바꿔서 저장을 한 번 일으킴.
    await enterEditMode(tester);
    await tester.tap(find.byIcon(Icons.push_pin_outlined));
    await tester.pumpAndSettle();

    final saved = await cachedLayout('local_after_테스트 공연');
    expect(
      saved!.items
          .where((i) => i.type == PageLayoutItemType.text)
          .map((i) => i.text),
      ['좋았다'],
    );
    expect(saved.items.any((i) => i.type == PageLayoutItemType.poster), isTrue);
  });

  for (final (name, size) in [
    ('태블릿', const Size(800, 1280)),
    ('폰', const Size(360, 640)),
  ]) {
    testWidgets('$name: 페이지가 화면 맨 위부터 시작해도 편집 도구가 페이지 안에 보이고 눌린다', (
      tester,
    ) async {
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ConcertAfterPageContents(
              concertTitle: '테스트 공연',
              ticketInfo: TicketInfo(concertName: '테스트 공연', ticketId: 't1'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 포스터가 없는 오른쪽 가운데 빈 곳을 꾹 눌러 편집 모드로.
      await tester.longPressAt(Offset(size.width * .85, size.height * .6));
      await tester.pumpAndSettle();

      final screen = Offset.zero & size;
      for (final label in ['사진 추가', '자동 배치', '편집 모드']) {
        final rect = tester.getRect(find.text(label));
        expect(
          screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
          isTrue,
          reason: '$label $rect',
        );
        expect(rect.bottom, greaterThan(size.height * .8), reason: '아래쪽 줄');
      }
      // 실제로 눌리는지: 자동 배치 → (메모가 없으니 확인창 없이) 로딩 표시.
      await tester.tap(find.text('자동 배치'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('세로 → 가로 → 세로로 돌려도 배치가 그대로 돌아오고 저장값도 안 바뀐다', (tester) async {
    const portrait = Size(800, 1280), landscape = Size(1280, 800);
    tester.view.physicalSize = portrait * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    const layout = PageLayout(
      canvasAspect: 1.6,
      items: [
        PageLayoutItem(
          id: 'poster',
          type: PageLayoutItemType.poster,
          cx: 0.3,
          cy: 0.4,
          w: 0.35,
          rot: 0.03,
        ),
        PageLayoutItem(
          id: 'a',
          type: PageLayoutItemType.photo,
          ref: 'https://example.com/a.jpg',
          cx: 0.7,
          cy: 0.6,
          w: 0.3,
          rot: -0.05,
          photo: PageLayoutPhoto(w: 1024, h: 768),
        ),
        PageLayoutItem(
          id: 'b',
          type: PageLayoutItemType.photo,
          ref: 'https://example.com/b.jpg',
          cx: 0.4,
          cy: 1.2,
          w: 0.4,
          rot: 0.02,
          photo: PageLayoutPhoto(w: 768, h: 1024),
        ),
        PageLayoutItem(
          id: 'text_m1',
          type: PageLayoutItemType.text,
          ref: 'm1',
          text: '최고',
          cx: 0.5,
          cy: 1.45,
          w: 0.3,
        ),
      ],
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConcertAfterPageContents(
            concertTitle: '테스트 공연',
            ticketInfo: TicketInfo(concertName: '테스트 공연', pageLayout: layout),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Rect photoRect(String id) => tester.getRect(
      find.byWidgetPredicate(
        (w) => w is AppNetworkImage && w.url.endsWith('/$id.jpg'),
      ),
    );
    final before = {
      for (final id in ['a', 'b']) id: photoRect(id),
    };

    // 가로: 전부 화면 안에 들어오게 축소돼 보여야 함.
    tester.view.physicalSize = landscape * 2;
    await tester.pumpAndSettle();
    final screen = Offset.zero & landscape;
    for (final id in ['a', 'b']) {
      final r = photoRect(id);
      expect(screen.contains(r.center), isTrue, reason: '$id $r');
    }
    expect(find.text('최고'), findsOneWidget);

    // 다시 세로: 원래 자리로.
    tester.view.physicalSize = portrait * 2;
    await tester.pumpAndSettle();
    for (final id in ['a', 'b']) {
      final r = photoRect(id);
      expect((r.center - before[id]!.center).distance, lessThan(1), reason: id);
      expect((r.width - before[id]!.width).abs(), lessThan(1), reason: id);
    }

    // 저장을 한 번 일으켜서 저장값(기준 좌표)이 원본과 같은지.
    await tester.longPressAt(const Offset(760, 200));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.push_pin_outlined).first);
    await tester.pumpAndSettle();
    final saved = await cachedLayout('local_after_테스트 공연');
    expect(saved!.canvasAspect, 1.6);
    for (final orig in layout.items) {
      final got = saved.items.singleWhere((i) => i.id == orig.id);
      final tol = orig.type == PageLayoutItemType.text ? 0.01 : 1e-6;
      expect(got.cx, closeTo(orig.cx, tol), reason: orig.id);
      expect(got.cy, closeTo(orig.cy, tol), reason: orig.id);
      expect(got.w, closeTo(orig.w, tol), reason: orig.id);
    }
  });

  const longTitle = '오피셜히게단디즘 아시아 투어 in SEOUL';

  Future<void> pumpTitlePage(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConcertAfterPageContents(
            concertTitle: longTitle,
            ticketInfo: TicketInfo(concertName: longTitle),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Text titleText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .firstWhere((t) => (t.data ?? '').replaceAll('\n', ' ') == longTitle);

  testWidgets('긴 공연명은 띄어쓰기 자리에서 두 줄 길이가 비슷하게 줄바꿈 (폰)', (tester) async {
    await pumpTitlePage(tester, const Size(400, 800));
    final lines = titleText(tester).data!.split('\n');
    expect(lines, hasLength(2));
    // 한쪽 줄에 단어 하나만 덩그러니 남지 않음.
    expect(lines.every((l) => l.trim().isNotEmpty), isTrue);
    expect(
      (lines[0].length - lines[1].length).abs(),
      lessThan(longTitle.length ~/ 2),
    );
  });

  testWidgets('태블릿만 공연명 0.85배, 하단 잠금 표시를 더 위로 (폰은 그대로)', (tester) async {
    double titleSize() => titleText(tester).style!.fontSize!;
    double badgeGap(Size size) =>
        size.height - tester.getRect(find.text('잠금 (꾹 눌러 편집)')).bottom;

    const phone = Size(400, 800);
    await pumpTitlePage(tester, phone);
    final phoneScale = (phone.width / 402).clamp(0.85, 1.8);
    expect(titleSize(), closeTo(24 * phoneScale, 1e-6));
    final phoneGap = badgeGap(phone);

    const tablet = Size(800, 1280);
    await pumpTitlePage(tester, tablet);
    const tabletScale = 1.8; // 800 / 402 → 상한 1.8
    expect(titleSize(), closeTo(24 * .85 * tabletScale, 1e-6));
    final tabletGap = badgeGap(tablet);

    // 폰: 8 × 배율 + 표시 자체 여백, 태블릿: 20 × 배율 + 여백.
    expect(
      tabletGap - phoneGap,
      greaterThan(20 * tabletScale - 8 * phoneScale - 2),
    );
  });

  for (final (name, size) in [
    ('폰', const Size(400, 800)),
    ('태블릿', const Size(800, 1280)),
  ]) {
    testWidgets('$name: 뒷면 실제 셋리스트 음악앱 아이콘이 제목과 같은 줄 옆에 있다', (tester) async {
      await pumpTitlePage(tester, size);
      // 가로로 밀어서 뒷면으로.
      await tester.fling(
        find.byType(ConcertAfterPageContents),
        const Offset(-300, 0),
        1500,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '좁은 칸에서도 넘침 없음');

      final title = tester.getRect(find.text('실제 셋 리스트').first);
      final icon = tester.getRect(find.byType(SetlistServiceIcon));
      final sameLine =
          icon.left >= title.right - 0.5 &&
          icon.center.dy >= title.top &&
          icon.center.dy <= title.bottom;
      // 칸이 좁으면(폰) 제목 바로 아래 줄로, 넓으면(태블릿) 제목 옆 같은 줄.
      final nextLine =
          icon.top >= title.bottom - 0.5 && icon.top - title.bottom < 8;
      expect(
        size.width >= 800 ? sameLine : (sameLine || nextLine),
        isTrue,
        reason: 'title=$title icon=$icon',
      );
    });
  }

  testWidgets('뒷면: 편집 모드 없이 셋리스트 제목 옆 "편집"으로 바로 편집 화면이 열린다', (tester) async {
    const size = Size(800, 1280);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConcertAfterPageContents(
            concertTitle: '테스트 공연',
            ticketInfo: TicketInfo(concertName: '테스트 공연', ticketId: 't1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 앞면에서 편집 모드로 들어간 채 뒷면으로 넘기면 편집 모드가 풀림.
    await tester.longPressAt(Offset(size.width * .85, size.height * .6));
    await tester.pumpAndSettle();
    expect(find.text('편집 모드'), findsOneWidget);
    await tester.fling(
      find.byType(ConcertAfterPageContents),
      const Offset(-300, 0),
      1500,
    );
    await tester.pumpAndSettle();

    // 제목 - [편집] - 음악앱 아이콘이 한 줄.
    final title = tester.getRect(find.text('실제 셋 리스트').first);
    final chip = tester.getRect(find.byTooltip('셋리스트 편집'));
    final icon = tester.getRect(find.byType(SetlistServiceIcon));
    expect(chip.left, greaterThanOrEqualTo(title.right - 0.5));
    expect(icon.left, greaterThanOrEqualTo(chip.right - 0.5));
    for (final r in [chip, icon]) {
      expect(r.center.dy, inInclusiveRange(title.top, title.bottom));
    }
    // 연필과 음악앱 아이콘은 같은 크기, 같은 세로 중심.
    expect((chip.center.dy - icon.center.dy).abs(), lessThan(0.5));
    expect((chip.height - icon.height).abs(), lessThan(0.5));

    await tester.tap(find.byTooltip('셋리스트 편집'));
    await tester.pumpAndSettle();
    expect(find.byType(SetlistEditorSheet), findsOneWidget);
    Navigator.of(tester.element(find.byType(SetlistEditorSheet))).pop();
    await tester.pumpAndSettle();

    // 다시 앞면: 편집 모드는 풀려 있음.
    await tester.fling(
      find.byType(ConcertAfterPageContents),
      const Offset(300, 0),
      1500,
    );
    await tester.pumpAndSettle();
    expect(find.text('잠금 (꾹 눌러 편집)'), findsOneWidget);
    expect(find.text('편집 모드'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(seconds: 1));
  });
}
