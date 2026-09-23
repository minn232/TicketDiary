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
            canvasAspect: 1.55,
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
}
