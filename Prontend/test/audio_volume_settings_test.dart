import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/widgets/audio_volume_settings.dart';

void main() {
  testWidgets('효과음과 미리듣기를 독립적으로 조절하고 저장한다', (tester) async {
    SharedPreferences.setMockInitialValues({
      'effects_volume': 0.8,
      'music_volume': 0.6,
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AudioVolumeSettings())),
    );
    await tester.pumpAndSettle();
    final effects = find.byKey(const ValueKey('effects-volume'));
    final music = find.byKey(const ValueKey('music-volume'));
    expect(find.byType(Slider), findsNWidgets(2));
    expect(tester.widget<Slider>(effects).value, 0.8);
    expect(tester.widget<Slider>(music).value, 0.6);
    tester.widget<Slider>(effects).onChanged!(0);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(effects).value, 0);
    expect(tester.widget<Slider>(music).value, 0.6);
    tester.widget<Slider>(music).onChanged!(0.3);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(effects).value, 0);
    expect(tester.widget<Slider>(music).value, 0.3);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('effects_volume'), 0);
    expect(prefs.getDouble('music_volume'), 0.3);
  });
}
