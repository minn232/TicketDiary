import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/screen/settings_screen.dart';
import 'package:ticketdiary/widgets/pressable_scale.dart';
import 'package:ticketdiary/widgets/summary_calendar.dart';

void main() {
  testWidgets('calendar date selection does not initialize an audio player', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    const audio = MethodChannel('com.ryanheise.just_audio.methods');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(audio, (
      call,
    ) async {
      calls.add(call);
      return {};
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        audio,
        null,
      ),
    );
    final selected = ValueNotifier(DateTime(2026, 8, 1));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SummaryCalendar(
            tickets: const [
              {'date': '2026-08-07', 'concert_name': '테스트 공연'},
            ],
            selection: selected,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-2026-8-7')));
    await tester.pumpAndSettle();
    expect(selected.value, DateTime(2026, 8, 7));
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    selected.dispose();
  });

  testWidgets('ordinary buttons no longer play a generated click sound', (
    tester,
  ) async {
    var tapped = false;
    final calls = <MethodCall>[];
    const audio = MethodChannel('com.ryanheise.just_audio.methods');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(audio, (
      call,
    ) async {
      calls.add(call);
      return {};
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        audio,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PressableScale(
            onTap: () => tapped = true,
            child: const Text('버튼'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('버튼'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
    expect(calls, isEmpty);
  });

  testWidgets(
    'sound and listening settings use right-facing collapsed arrows',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();
      for (final title in ['소리 설정', '공연 감상 설정']) {
        final row = find.ancestor(
          of: find.text(title),
          matching: find.byType(ExpansionTile),
        );
        expect(
          (tester.widget<ExpansionTile>(row).trailing as Icon).icon,
          Icons.keyboard_arrow_right,
        );
      }
      await tester.tap(find.text('공연 감상 설정'));
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: find.text('공연 감상 설정'),
        matching: find.byType(ExpansionTile),
      );
      expect(
        (tester.widget<ExpansionTile>(row).trailing as Icon).icon,
        Icons.keyboard_arrow_down,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
