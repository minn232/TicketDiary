import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'summary_map_drawing.dart';

/// WGS84 polygons remain unprojected for venue point-in-polygon matching.
class SummaryMapRegion {
  final String id;
  final String name;
  final String? parent;
  final Offset anchor;
  final List<List<List<Offset>>> polygons;
  late final Path geographicPath = buildPath((p) => p);

  SummaryMapRegion({
    required this.id,
    required this.name,
    this.parent,
    required this.anchor,
    required this.polygons,
  });

  Path buildPath(Offset Function(Offset) project) {
    final path = Path()..fillType = PathFillType.evenOdd;
    for (final polygon in polygons) {
      for (final ring in polygon) {
        if (ring.isEmpty) continue;
        final start = project(ring.first);
        path.moveTo(start.dx, start.dy);
        for (final point in ring.skip(1)) {
          final p = project(point);
          path.lineTo(p.dx, p.dy);
        }
        path.close();
      }
    }
    return path;
  }

  bool contains(Offset location) => geographicPath.contains(location);
}

class SummaryMapData {
  final List<SummaryMapRegion> regions;
  const SummaryMapData(this.regions);
  static Future<SummaryMapData>? _cached;
  static bool _licenseRegistered = false;
  static Future<SummaryMapData> load() => _cached ??= _load();
  static Future<SummaryMapData> _load() async {
    try {
      if (!_licenseRegistered) {
        LicenseRegistry.addLicense(() async* {
          yield LicenseEntryWithLineBreaks([
            'Regional attendance location data',
          ], await rootBundle.loadString('assets/maps/LICENSE-DATA.txt'));
        });
        _licenseRegistered = true;
      }
      return await compute(
        parse,
        await rootBundle.loadString('assets/maps/korea.json'),
      );
    } catch (_) {
      _cached = null;
      rethrow;
    }
  }

  static SummaryMapData parse(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    Offset point(dynamic p) =>
        Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
    return SummaryMapData(
      (json['regions'] as List).map((r) {
        final g = r['geometry'];
        final List polygons = g['type'] == 'Polygon'
            ? [g['coordinates']]
            : g['coordinates'];
        return SummaryMapRegion(
          id: r['id'],
          name: r['name'],
          parent: r['parent'],
          anchor: point(r['anchor']),
          polygons: polygons
              .map(
                (polygon) => (polygon as List)
                    .map((ring) => (ring as List).map(point).toList())
                    .toList(),
              )
              .toList(),
        );
      }).toList(),
    );
  }

  List<SummaryMapRegion> children(String? parent) =>
      regions.where((r) => r.parent == parent).toList();

  Map<String, int> countVisits(List<SummaryMapVisit> visits) {
    final counts = <String, int>{};
    final subdivisions = regions.where((r) => r.parent != null);
    for (final visit in visits) {
      for (final region in subdivisions) {
        if (!region.contains(visit.location)) continue;
        counts.update(
          region.id,
          (v) => v + visit.count,
          ifAbsent: () => visit.count,
        );
        counts.update(
          region.parent!,
          (v) => v + visit.count,
          ifAbsent: () => visit.count,
        );
        break;
      }
    }
    return counts;
  }
}

class SummaryMapVisit {
  final Offset location;
  final int count;
  const SummaryMapVisit(this.location, this.count);
}

/// Uniform fit: no separate horizontal/vertical scaling, skew, or stretching.
class SummaryMapLayout {
  final Map<String, Path> paths = {};
  final Map<String, Path> raisedFaces = {};
  final Map<String, Offset> anchors = {};
  final Map<String, Rect> labelRects = {};
  SummaryMapLayout(List<SummaryMapRegion> regions, Size size) {
    final polygons = SummaryMapDrawing.polygons(regions, viewport: size);
    if (polygons.isEmpty || size.isEmpty) return;
    final points = polygons.values.expand((p) => p).expand((r) => r).toList();
    final minX = points.map((p) => p.dx).reduce(math.min);
    final maxX = points.map((p) => p.dx).reduce(math.max);
    final minY = points.map((p) => p.dy).reduce(math.min);
    final maxY = points.map((p) => p.dy).reduce(math.max);
    final scale = math.min(
      math.max(1, size.width - 14) / (maxX - minX),
      math.max(1, size.height - 17) / (maxY - minY),
    );
    final center = Offset((minX + maxX) / 2, (minY + maxY) / 2);
    final destination = Offset(size.width / 2 - 2, size.height / 2 - 3);
    Offset project(Offset p) => (p - center) * scale + destination;
    final latitude =
        regions.map((r) => r.anchor.dy).reduce((a, b) => a + b) /
        regions.length;
    final longitudeScale = math.cos(latitude * math.pi / 180);
    for (final region in regions) {
      final path = Path()..fillType = PathFillType.evenOdd;
      final raised = Path()..fillType = PathFillType.evenOdd;
      for (final ring in polygons[region.id]!) {
        final part = Path()..addPolygon(ring.map(project).toList(), true);
        path.addPath(part, Offset.zero);
        final bounds = part.getBounds();
        if (bounds.width * bounds.height >= 9) {
          raised.addPath(part, Offset.zero);
        }
      }
      paths[region.id] = path;
      raisedFaces[region.id] = raised;
      anchors[region.id] = project(
        Offset(region.anchor.dx * longitudeScale, -region.anchor.dy),
      );
    }
  }

  String? hitTest(Offset point) {
    // Labels are deliberately larger than fine boundaries and take precedence.
    for (final entry in labelRects.entries) {
      if (entry.value.contains(point)) return entry.key;
    }
    for (final entry in paths.entries.toList().reversed) {
      if (entry.value.contains(point)) return entry.key;
    }
    return null;
  }
}
