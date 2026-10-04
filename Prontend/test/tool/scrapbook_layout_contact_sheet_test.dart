// 자동 배치 결과를 PNG 한 장으로 모아 눈으로 튜닝하는 개발용 도구.
// LAYOUT_SHEET_OUT 환경변수가 있을 때만 실행:
//   LAYOUT_SHEET_OUT=out.png flutter test test/tool/scrapbook_layout_contact_sheet_test.dart
// LAYOUT_PHOTOS_DIR에 jpg/png 폴더를 주면 색 블록 대신 실제 사진으로 그림
// 폴더에 times.json(파일명 → ISO 촬영 시각)이 있으면 날짜별 세트 + 유사샷 스택으로 비교.
// LAYOUT_DAYS=YYYY-MM-DD,... 를 주면 그 날짜 세트만 한 열씩.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/services/photo_quality.dart';
import 'package:ticketdiary/services/scrapbook_auto_layout.dart';

const _cellW = 300.0;
const _gap = 16.0;
const _canvases = [
  LayoutCanvas(aspect: 1.55, reserved: [LayoutRect(0, 0, 1, 0.12)]),
  LayoutCanvas(aspect: 1.3, reserved: [LayoutRect(0, 0, 1, 0.1)]),
];

const _poster = LayoutItem(
  id: 'poster',
  kind: LayoutItemKind.poster,
  aspect: 0.75,
  fixedWidth: 0.34,
);

List<LayoutItem> _randomItems(math.Random r, int photos) {
  const aspects = [4 / 3, 3 / 4, 16 / 9, 9 / 16, 1.0, 3 / 2, 2 / 3];
  return [
    _poster,
    for (var i = 0; i < photos; i++)
      LayoutItem(
        id: 'p$i',
        kind: LayoutItemKind.photo,
        aspect: aspects[r.nextInt(aspects.length)],
        quality: r.nextDouble(),
        faces: r.nextDouble() < 0.4
            ? const [LayoutRect(0.35, 0.2, 0.65, 0.5)]
            : const [],
      ),
  ];
}

class _Photo {
  _Photo(this.id, this.image, this.stats);
  final String id;
  final ui.Image image;
  final PhotoStats stats;
}

Future<ui.Image> _decode(List<int> bytes, {int? targetWidth}) async {
  final codec = await ui.instantiateImageCodec(
    Uint8List.fromList(bytes),
    targetWidth: targetWidth,
  );
  return (await codec.getNextFrame()).image;
}

Future<List<_Photo>> _loadPhotos(
  String dir, {
  bool Function(String name)? include,
}) async {
  final files =
      Directory(dir)
          .listSync()
          .whereType<File>()
          .where(
            (f) => RegExp(
              r'\.(jpe?g|png)$',
              caseSensitive: false,
            ).hasMatch(f.path),
          )
          .where((f) => include?.call(f.uri.pathSegments.last) ?? true)
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final photos = <_Photo>[];
  for (final f in files) {
    final bytes = f.readAsBytesSync();
    final full = await _decode(bytes);
    // 긴 변 128px 축소본으로 화질 통계.
    final small = await _decode(
      bytes,
      targetWidth: full.width >= full.height
          ? 128
          : (128 * full.width / full.height).round(),
    );
    final raw = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
    photos.add(
      _Photo(
        f.uri.pathSegments.last,
        full,
        PhotoStats.fromRgba(
          raw!.buffer.asUint8List(),
          small.width,
          small.height,
        ),
      ),
    );
  }
  return photos;
}

void _drawLayout(
  Canvas c,
  Offset origin,
  LayoutCanvas canvas,
  List<LayoutItem> items,
  LayoutResult result, {
  Map<String, ui.Image> images = const {},
}) {
  final s = _cellW;
  c.save();
  c.translate(origin.dx, origin.dy);
  c.drawRect(
    Rect.fromLTWH(0, 0, s, s * canvas.aspect),
    Paint()..color = const Color(0xFFF3ECDD),
  );
  for (final r in canvas.reserved) {
    c.drawRect(
      Rect.fromLTRB(r.left * s, r.top * s, r.right * s, r.bottom * s),
      Paint()..color = const Color(0x33C0392B),
    );
  }
  final byId = {for (final it in items) it.id: it};
  final sorted = [...result.placements]..sort((a, b) => a.z.compareTo(b.z));
  for (final p in sorted) {
    final it = byId[p.id]!;
    final fill = switch (it.kind) {
      LayoutItemKind.poster => const Color(0xFF2E4A7D),
      LayoutItemKind.photo => [
        const Color(0xFF7A3E9D),
        const Color(0xFF3E8E7E),
        const Color(0xFF8E8E8E),
      ][p.tier],
    };
    c.save();
    c.translate(p.cx * s, p.cy * s);
    c.rotate(p.rotation);
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: p.width * s,
      height: p.height * s,
    );
    c.drawRect(
      rect.shift(const Offset(2, 3)),
      Paint()..color = const Color(0x33000000),
    );
    final image = images[p.id];
    if (it.kind == LayoutItemKind.photo) {
      // 폴라로이드 흰 테두리 느낌.
      c.drawRect(rect, Paint()..color = Colors.white);
      final inner = rect.deflate(4);
      if (image != null) {
        c.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          inner,
          Paint()..filterQuality = FilterQuality.medium,
        );
      } else {
        c.drawRect(inner, Paint()..color = fill);
      }
    } else {
      c.drawRect(rect, Paint()..color = fill);
    }
    for (final f in it.faces) {
      c.drawRect(
        Rect.fromLTRB(
          rect.left + f.left * rect.width,
          rect.top + f.top * rect.height,
          rect.left + f.right * rect.width,
          rect.top + f.bottom * rect.height,
        ),
        Paint()
          ..color = const Color(0xFFFFD54F)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    c.restore();
  }
  c.restore();
}

Future<void> _writeSheet(
  String out,
  int cols,
  void Function(Canvas c, Offset Function(int row, int col) at) paint,
) async {
  final maxH = _canvases.map((c) => c.aspect).reduce(math.max) * _cellW;
  final width = cols * (_cellW + _gap) + _gap;
  final height = _canvases.length * (maxH + _gap) + _gap;
  final recorder = ui.PictureRecorder();
  final c = Canvas(recorder);
  c.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFF3B2B22),
  );
  paint(
    c,
    (row, col) =>
        Offset(_gap + col * (_cellW + _gap), _gap + row * (maxH + _gap)),
  );
  final image = await recorder.endRecording().toImage(
    width.ceil(),
    height.ceil(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(out).writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  final out = Platform.environment['LAYOUT_SHEET_OUT'];
  final photosDir = Platform.environment['LAYOUT_PHOTOS_DIR'];

  test('contact sheet', () async {
    if (photosDir == null) {
      const counts = [2, 4, 6, 9, 12];
      final r = math.Random(7);
      await _writeSheet(out!, counts.length, (c, at) {
        for (var row = 0; row < _canvases.length; row++) {
          for (var col = 0; col < counts.length; col++) {
            final items = _randomItems(r, counts[col]);
            final result = autoLayout(items, _canvases[row], seed: col);
            _drawLayout(c, at(row, col), _canvases[row], items, result);
          }
        }
      });
      return;
    }

    // times.json(파일명 → 촬영 시각)이 있으면 날짜별 세트 + 유사샷 스택.
    final timesFile = File('$photosDir/times.json');
    final times = timesFile.existsSync()
        ? (jsonDecode(timesFile.readAsStringSync()) as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, DateTime.parse(v as String)))
        : <String, DateTime>{};
    String dayOf(String name) =>
        times[name]?.toIso8601String().substring(0, 10) ?? 'unknown';
    // LAYOUT_DAYS=2024-08-17,2025-03-23 처럼 주면 그 날짜만 한 열씩 (스택 적용).
    final days = Platform.environment['LAYOUT_DAYS']?.split(',');
    final photos = await _loadPhotos(
      photosDir,
      include: days == null ? null : (name) => days.contains(dayOf(name)),
    );
    final images = {for (final p in photos) p.id: p.image};
    final byDay = <String, List<_Photo>>{};
    for (final p in photos) {
      byDay.putIfAbsent(dayOf(p.id), () => []).add(p);
    }
    final biggest = byDay.values.reduce((a, b) => a.length >= b.length ? a : b);
    // 열: 가장 큰 날짜 세트(스택 없음 / 스택) + 나머지 날짜 세트(스택) + 전체(스택)
    final columns = <(String, List<_Photo>, bool)>[
      if (days != null)
        for (final d in days)
          if (byDay[d] != null) ('$d (${byDay[d]!.length})', byDay[d]!, true),
      if (days == null) ...[
        ('no-stack', biggest, false),
        ('stack', biggest, true),
        for (final e in byDay.entries)
          if (!identical(e.value, biggest)) ('stack ${e.key}', e.value, true),
        ('stack all', photos, true),
      ],
    ];
    await _writeSheet(out!, columns.length, (c, at) {
      for (var col = 0; col < columns.length; col++) {
        final (label, set, stack) = columns[col];
        final scores = scorePhotoSet([for (final p in set) p.stats]);
        // 유사샷 스택 비활성화 - 다시 켤 때는 아래 주석을 풀면 됨.
        // final groups = stack
        //     ? groupSimilarShots([
        //         for (final p in set)
        //           ShotInfo(takenAt: times[p.id], stats: p.stats),
        //       ])
        //     : List<int?>.filled(set.length, null);
        final groups = List<int?>.filled(set.length, null);
        // ignore: avoid_print
        print('[$label]');
        for (var i = 1; i < set.length; i++) {
          final gap = times[set[i].id] != null && times[set[i - 1].id] != null
              ? times[set[i].id]!.difference(times[set[i - 1].id]!).inSeconds
              : null;
          // ignore: avoid_print
          print(
            '  ${set[i - 1].id}~${set[i].id} gap=${gap}s '
            'color=${colorLayoutDistance(set[i - 1].stats, set[i].stats).toStringAsFixed(3)}',
          );
        }
        final items = [
          _poster,
          for (var i = 0; i < set.length; i++)
            LayoutItem(
              id: set[i].id,
              kind: LayoutItemKind.photo,
              aspect: set[i].image.width / set[i].image.height,
              quality: scores[i],
              stackGroup: groups[i] == null ? null : 'g${groups[i]}',
            ),
        ];
        for (var row = 0; row < _canvases.length; row++) {
          final result = autoLayout(items, _canvases[row], seed: col);
          if (row == 0) {
            for (final p in result.placements.where((p) => p.tier >= 0)) {
              final i = set.indexWhere((x) => x.id == p.id);
              // ignore: avoid_print
              print(
                '  ${p.id} score=${scores[i].toStringAsFixed(2)} tier=${p.tier}'
                '${p.stackOf == null ? '' : ' behind=${p.stackOf}'}',
              );
            }
            // ignore: avoid_print
            print('  ${result.metrics}');
          }
          _drawLayout(
            c,
            at(row, col),
            _canvases[row],
            items,
            result,
            images: images,
          );
        }
      }
    });
  }, skip: out == null);
}
