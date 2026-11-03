import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/widgets/app_back_handler.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/diary_route.dart';
import 'package:ticketdiary/widgets/tab_nav_coordinator.dart';

void main() {
  setUp(TabNavCoordinator.resetForTest);
  tearDown(TabNavCoordinator.resetForTest);

  testWidgets('내부 상태를 먼저 닫고 홈에서만 시스템 뒤로가기를 실행한다', (tester) async {
    var expanded = true;
    var exits = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') exits++;
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
        theme: ThemeData(platform: TargetPlatform.android),
        home: AppBackHandler(
          canHandle: () => expanded,
          onBack: () {
            expanded = false;
          },
          child: const DiaryPageFrame(isTabRoot: true, child: SizedBox()),
        ),
      ),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(expanded, false);
    expect(exits, 0);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(exits, 1);
  });

  testWidgets('설정에서 뒤로가면 다이어리 탭으로 돌아간다', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final tabs = TabNavCoordinator.init(
      navigatorKey: key,
      initialTab: DiaryTab.settings,
      routeBuilder: (_, to) =>
          MaterialPageRoute<void>(builder: (_) => Text(to.name)),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        home: const DiaryPageFrame(isTabRoot: true, child: SizedBox()),
      ),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tabs.currentTab.value, DiaryTab.diary);
    expect(find.text('diary'), findsOneWidget);
  });

  testWidgets('최상위 팝업을 닫을 때 아래 페이지 상태는 그대로다', (tester) async {
    var expanded = true;
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return AppBackHandler(
              canHandle: () => expanded,
              onBack: () {
                expanded = false;
              },
              child: const DiaryPageFrame(isTabRoot: true, child: SizedBox()),
            );
          },
        ),
      ),
    );
    unawaited(
      showDialog<void>(
        context: ctx,
        builder: (_) => const AlertDialog(content: Text('popup')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('popup'), findsNothing);
    expect(expanded, true);
  });

  testWidgets('저장 중 닫힘 방지와 미저장 변경 확인', (tester) async {
    var saving = true;
    var dirty = true;
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );
    unawaited(
      showDialog<void>(
        context: ctx,
        builder: (_) => DiscardChangesGuard(
          isSaving: () => saving,
          isDirty: () => dirty,
          child: const AlertDialog(content: Text('editor')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('editor'), findsOneWidget);
    expect(find.text('수정을 취소할까요?'), findsNothing);
    saving = false;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('수정을 취소할까요?'), findsOneWidget);
    await tester.tap(find.text('계속 편집'));
    await tester.pumpAndSettle();
    expect(find.text('editor'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('버리고 닫기'));
    await tester.pumpAndSettle();
    expect(find.text('editor'), findsNothing);
    dirty = false;
  });
}
