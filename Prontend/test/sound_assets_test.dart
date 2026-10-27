import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/services/sound_effect_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'retained recordings are bundled; the old sound folder is absent',
    () async {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      expect(
        manifest.listAssets().where(
          (path) => path.startsWith('assets/sounds/'),
        ),
        isEmpty,
      );
      for (final asset in SoundEffectService.assets.values) {
        final data = await rootBundle.load(asset);
        expect(data.lengthInBytes, greaterThan(44));
        expect(
          ascii.decode(data.buffer.asUint8List(data.offsetInBytes, 4)),
          'RIFF',
        );
      }
    },
  );
}
