import 'dart:math' as math;
import 'dart:ui';
import 'summary_map.dart';

/// Simplified geographic outlines, rather than equal-area diagram cells.
/// One longitude correction is shared by every region in the same view.
class SummaryMapDrawing {
  static Map<String, List<List<Offset>>> polygons(
    List<SummaryMapRegion> regions, {
    Size viewport = const Size(300, 460),
  }) {
    if (regions.isEmpty) return {};
    final latitude =
        regions.map((r) => r.anchor.dy).reduce((a, b) => a + b) /
        regions.length;
    final longitudeScale = math.cos(latitude * math.pi / 180);
    Offset project(Offset p) => Offset(p.dx * longitudeScale, -p.dy);
    double area(List<Offset> ring) {
      var result = 0.0;
      for (var i = 0; i < ring.length; i++) {
        final next = ring[(i + 1) % ring.length];
        result += ring[i].dx * next.dy - next.dx * ring[i].dy;
      }
      return result.abs() / 2;
    }

    final visible = <String, List<List<List<Offset>>>>{};
    for (final region in regions) {
      final largest = region.polygons
          .map((p) => area(p.first))
          .reduce(math.max);
      visible[region.id] = region.polygons
          .where((p) => area(p.first) >= largest * .08)
          .toList();
    }
    // Evaluate actual touch size, not only the island's share of its province.
    // Always retain the largest landmass of each selectable administrative area
    // (including island-only regions), and keep holes with their owning polygon.
    final primary = <String, List<List<Offset>>>{
      for (final region in regions)
        region.id: visible[region.id]!.reduce(
          (a, b) => area(a.first) >= area(b.first) ? a : b,
        ),
    };
    for (var pass = 0; pass < 3; pass++) {
      final vertices = visible.values
          .expand((p) => p)
          .expand((p) => p.first)
          .map(project)
          .toList();
      final spanX =
          vertices.map((p) => p.dx).reduce(math.max) -
          vertices.map((p) => p.dx).reduce(math.min);
      final spanY =
          vertices.map((p) => p.dy).reduce(math.max) -
          vertices.map((p) => p.dy).reduce(math.min);
      final scale = math.min(
        math.max(1, viewport.width - 14) / spanX,
        math.max(1, viewport.height - 17) / spanY,
      );
      var removed = false;
      for (final region in regions) {
        visible[region.id] = visible[region.id]!.where((polygon) {
          if (identical(polygon, primary[region.id])) return true;
          final path = Path()
            ..addPolygon(polygon.first.map(project).toList(), true);
          final bounds = path.getBounds();
          final keep =
              math.min(bounds.width, bounds.height) * scale >= 24 &&
              area(polygon.first) * longitudeScale * scale * scale >= 24 * 24;
          if (!keep) removed = true;
          return keep;
        }).toList();
      }
      if (!removed) break;
    }
    final points = regions
        .expand((r) => visible[r.id]!)
        .expand((p) => p.first)
        .map(project)
        .toList();
    final width =
        points.map((p) => p.dx).reduce(math.max) -
        points.map((p) => p.dx).reduce(math.min);
    final height =
        points.map((p) => p.dy).reduce(math.max) -
        points.map((p) => p.dy).reduce(math.min);
    final tolerance = math.max(width, height) * .005;
    return {
      for (final region in regions)
        region.id: [
          for (final polygon in visible[region.id]!)
            for (final ring in polygon)
              simplifyClosed(ring.map(project).toList(), tolerance),
        ],
    };
  }

  /// Split a closed ring into two open chains before Douglas–Peucker so its
  /// start/end coincidence cannot erase a whole island or administrative area.
  static List<Offset> simplifyClosed(List<Offset> points, double tolerance) {
    if (points.length <= 4) return points;
    final ring = [...points];
    if (ring.first == ring.last) ring.removeLast();
    var opposite = 1;
    for (var i = 2; i < ring.length; i++) {
      if ((ring[i] - ring.first).distanceSquared >
          (ring[opposite] - ring.first).distanceSquared) {
        opposite = i;
      }
    }
    final first = _simplify(ring.sublist(0, opposite + 1), tolerance);
    final second = _simplify([
      ...ring.sublist(opposite),
      ring.first,
    ], tolerance);
    final result = [...first, ...second.skip(1)];
    return result.length < 4 ? points : result;
  }

  static List<Offset> _simplify(List<Offset> points, double tolerance) {
    if (points.length <= 2) return points;
    final a = points.first;
    final delta = points.last - a;
    var distance = 0.0;
    var index = 0;
    for (var i = 1; i < points.length - 1; i++) {
      final t = delta.distanceSquared == 0
          ? 0.0
          : (((points[i] - a).dx * delta.dx + (points[i] - a).dy * delta.dy) /
                    delta.distanceSquared)
                .clamp(0.0, 1.0);
      final d = (points[i] - (a + delta * t)).distance;
      if (d > distance) {
        distance = d;
        index = i;
      }
    }
    if (distance <= tolerance) return [points.first, points.last];
    return [
      ..._simplify(points.sublist(0, index + 1), tolerance),
      ..._simplify(points.sublist(index), tolerance).skip(1),
    ];
  }
}
