import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('All sound effects are bundled as non-silent PCM WAV assets', () async {
    for (final name in [
      'click',
      'calendar',
      'success',
      'page_flip',
      'book_open',
      'page_rustle',
      'tear',
    ]) {
      final data = await rootBundle.load('assets/sounds/$name.wav');
      expect(
        ascii.decode(data.buffer.asUint8List(data.offsetInBytes, 4)),
        'RIFF',
      );
      expect(data.getUint16(22, Endian.little), 1);
      expect(data.getUint16(34, Endian.little), 16);
      var peak = 0;
      for (var i = 44; i + 1 < data.lengthInBytes; i += 2) {
        final sample = data.getInt16(i, Endian.little).abs();
        if (sample > peak) peak = sample;
      }
      expect(peak, greaterThan(1000), reason: '$name must not be silent');
    }
  });
}
