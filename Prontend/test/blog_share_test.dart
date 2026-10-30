import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
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

void main() {
  for (final outcome in ['success', 'missing', 'error', 'bothFail']) {
    for (final draft in <String?>[null, '공연 후기\n정말 즐거운 공연이었다.']) {
      testWidgets(
        '블로그 공유 $outcome: ${draft == null ? '미연결은 복사 없이 이동' : '복사 후 이동'}',
        (tester) async {
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
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ConcertAfterShareSheet(
                  pageSize: const Size(300, 400),
                  pageBuilder: ({required back, required hideMemos}) =>
                      const SizedBox(),
                  images: const [],
                  pending: const [],
                  infoText: '',
                  fileStem: 'test',
                  loadBlogDraft: draft == null ? null : () async => draft,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.getCenter(find.text('블로그 공유')).dx,
            greaterThan(tester.getCenter(find.text('사진첩 저장')).dx),
          );
          expect(
            tester.getCenter(find.text('블로그 공유')).dx,
            lessThan(tester.getCenter(find.text('더보기')).dx),
          );
          await tester.tap(find.text('블로그 공유'));
          await tester.pumpAndSettle();
          expect(events, [
            ?draft,
            'naversearchapp://inappbrowser?url=https%3A%2F%2Fblog.naver.com%2FGoBlogWrite.naver&target=new&version=6',
            if (outcome != 'success')
              'https://blog.naver.com/GoBlogWrite.naver',
          ]);
          if (outcome == 'bothFail') {
            expect(find.textContaining('네이버 블로그를 열지 못했어요.'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
