import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:ticketdiary/services/blog_draft_service.dart';
import 'package:ticketdiary/widgets/concert_after_share_sheet.dart';

class _Launcher extends UrlLauncherPlatform {
  final List<String> events;
  final String outcome;
  _Launcher(this.events, this.outcome);
  @override
  Null get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    events.add(url);
    if (url.startsWith('naversearchapp:')) {
      if (outcome == 'error') throw PlatformException(code: 'unavailable');
      return outcome == 'success';
    }
    if (outcome == 'bothFail') return false;
    return true;
  }
}

Future<List<String>> _tapBlog(
  WidgetTester tester, {
  required String outcome,
  Future<BlogDraft> Function()? loadBlogDraft,
}) async {
  final events = <String>[];
  final previous = UrlLauncherPlatform.instance;
  UrlLauncherPlatform.instance = _Launcher(events, outcome);
  addTearDown(() => UrlLauncherPlatform.instance = previous);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        events.add(call.arguments['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ConcertAfterShareSheet(
          pageSize: const Size(300, 400),
          pageBuilder: ({required back}) => const SizedBox(),
          images: const [],
          pending: const [],
          infoText: '',
          fileStem: 'test',
          loadBlogDraft: loadBlogDraft,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    tester.getCenter(find.text('블로그')).dx,
    greaterThan(tester.getCenter(find.text('사진 저장')).dx),
  );
  expect(
    tester.getCenter(find.text('블로그')).dx,
    lessThan(tester.getCenter(find.text('더보기')).dx),
  );
  await tester.tap(find.text('블로그'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return events;
}

void main() {
  const text = '공연 후기\n\n정말 즐거운 공연이었다.';

  for (final outcome in ['success', 'missing', 'error', 'bothFail']) {
    testWidgets('블로그 공유 $outcome: 정리된 글이면 복사 후 이동', (tester) async {
      final events = await _tapBlog(
        tester,
        outcome: outcome,
        loadBlogDraft: () async =>
            const BlogDraft(status: BlogDraftStatus.done, text: text),
      );
      expect(events, [
        text,
        'naversearchapp://inappbrowser?url=https%3A%2F%2Fblog.naver.com%2FGoBlogWrite.naver&target=new&version=6',
        if (outcome != 'success') 'https://blog.naver.com/GoBlogWrite.naver',
      ]);
      if (outcome == 'bothFail') {
        expect(find.textContaining('네이버 블로그를 열지 못했어요.'), findsOneWidget);
      }
    });
  }

  final now = DateTime.now().toUtc();
  final waiting = <String, (BlogDraft, String)>{
    '메모 없음': (BlogDraft.empty, '감상 메모를 적으면'),
    '정리 대기': (
      BlogDraft(status: BlogDraftStatus.pending, requestedAt: now),
      '감상 메모를 정리하고 있어요',
    ),
    '고친 뒤 대기(이전 글 있음)': (
      BlogDraft(status: BlogDraftStatus.stale, text: text, requestedAt: now),
      '감상 메모를 정리하고 있어요',
    ),
    '자정 지나도 정리 전': (
      BlogDraft(
        status: BlogDraftStatus.pending,
        requestedAt: now.subtract(const Duration(days: 2)),
      ),
      '글 정리가 늦어지고 있어요',
    ),
    '정리 실패': (const BlogDraft(status: BlogDraftStatus.failed), '글로 정리하지 못했어요'),
  };
  for (final MapEntry(key: name, value: (draft, message)) in waiting.entries) {
    testWidgets('블로그 공유 $name: 복사·이동 없이 안내만', (tester) async {
      final events = await _tapBlog(
        tester,
        outcome: 'success',
        loadBlogDraft: () async => draft,
      );
      expect(events, isEmpty);
      expect(find.textContaining(message), findsOneWidget);
    });
  }

  testWidgets('블로그 공유 미연결: 복사·이동 없이 안내만', (tester) async {
    final events = await _tapBlog(tester, outcome: 'success');
    expect(events, isEmpty);
    expect(find.textContaining('감상 메모를 적으면'), findsOneWidget);
  });
}
