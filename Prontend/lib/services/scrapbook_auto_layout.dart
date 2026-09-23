import 'dart:math' as math;

/// 공연후 페이지 자동 배치 (순수 계산). 캔버스 폭 = 1, 높이 = [LayoutCanvas.aspect], 회전은 라디안.
/// 흐름: 크기 티어 결정 → 점유 맵 초기 배치 → 국소 개선(담금질) → 겹침 보정.

enum LayoutItemKind { poster, photo }

/// 축 정렬 사각형. 캔버스 좌표 또는 아이템 내부 정규화 좌표(0~1)로 씀.
class LayoutRect {
  const LayoutRect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
}

/// 유저가 직접 옮긴 아이템의 위치 (재배치해도 그대로 둠).
class LayoutPin {
  const LayoutPin({
    required this.cx,
    required this.cy,
    required this.width,
    this.rotation = 0,
  });

  final double cx;
  final double cy;
  final double width;
  final double rotation;
}

class LayoutItem {
  const LayoutItem({
    required this.id,
    required this.kind,
    required this.aspect,
    this.quality = 0.5,
    this.faces = const [],
    this.fixedWidth,
    this.stackGroup,
    this.pin,
  });

  final String id;
  final LayoutItemKind kind;

  /// 가로/세로 비율(EXIF 회전 적용 후).
  final double aspect;

  /// 0~1 화질 점수. 사진 크기 티어 결정에만 사용.
  final double quality;

  /// 얼굴 영역(아이템 내부 0~1 좌표). 비어 있으면 가운데 영역을 보호.
  final List<LayoutRect> faces;

  /// 포스터처럼 크기가 정해진 아이템의 폭.
  final double? fixedWidth;

  /// 같은 값끼리 연사/유사샷 묶음 (`groupSimilarShots` 결과). 화질 좋은 한 장만
  /// 배치 대상이 되고 나머지는 그 뒤에 겹쳐 쌓임.
  final String? stackGroup;

  /// 있으면 이 위치/크기/회전으로 고정. 옮기지 않지만 겹침/여백 계산에는 포함.
  final LayoutPin? pin;
}

class LayoutCanvas {
  const LayoutCanvas({required this.aspect, this.reserved = const []});

  /// 높이/폭.
  final double aspect;

  /// 아이템이 들어가면 안 되는 영역(제목 등).
  final List<LayoutRect> reserved;
}

class LayoutPlacement {
  const LayoutPlacement({
    required this.id,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
    required this.rotation,
    required this.z,
    required this.tier,
    this.stackOf,
  });

  final String id;
  final double cx;
  final double cy;
  final double width;
  final double height;
  final double rotation;
  final int z;

  /// 0 = 대, 1 = 중, 2 = 소, -1 = 포스터. 스택 뒤 사진은 리더와 같은 티어.
  final int tier;

  /// 스택 뒤에 깔린 사진이면 앞 사진(리더) id.
  final String? stackOf;

  Map<String, Object> toJson() => {
    'id': id,
    'cx': cx,
    'cy': cy,
    'w': width,
    'h': height,
    'rot': rotation,
    'z': z,
    'stackOf': ?stackOf,
  };
}

class LayoutMetrics {
  const LayoutMetrics({
    required this.coverage,
    required this.targetCoverage,
    required this.largestHole,
    required this.maxOverlap,
    required this.outOfCanvas,
    required this.reservedIntrusion,
    required this.maxProtectedOcclusion,
    required this.maxHidden,
  });

  /// 가용 영역 중 아이템이 덮은 비율.
  final double coverage;
  final double targetCoverage;

  /// 가장 큰 빈 정사각형의 한 변(캔버스 폭 기준).
  final double largestHole;

  /// 두 아이템 겹침 면적 / 작은 쪽 면적의 최댓값.
  final double maxOverlap;

  /// 캔버스 밖으로 나간 면적 합.
  final double outOfCanvas;

  /// 예약 영역을 침범한 면적 합.
  final double reservedIntrusion;

  /// 보호 영역(얼굴/가운데)이 위 아이템에 가려진 비율의 최댓값.
  final double maxProtectedOcclusion;

  /// 한 아이템이 위 아이템들에 가려진 총 비율의 최댓값.
  final double maxHidden;

  @override
  String toString() =>
      'coverage=${coverage.toStringAsFixed(3)}/${targetCoverage.toStringAsFixed(2)} '
      'hole=${largestHole.toStringAsFixed(3)} overlap=${maxOverlap.toStringAsFixed(3)} '
      'out=${outOfCanvas.toStringAsFixed(4)} reserved=${reservedIntrusion.toStringAsFixed(4)} '
      'occlusion=${maxProtectedOcclusion.toStringAsFixed(3)} hidden=${maxHidden.toStringAsFixed(3)}';
}

class LayoutResult {
  const LayoutResult({
    required this.placements,
    required this.energy,
    required this.metrics,
    required this.seed,
  });

  final List<LayoutPlacement> placements;
  final double energy;
  final LayoutMetrics metrics;
  final int seed;
}

/// 배치 파라미터. 원격 config(JSON)로 덮어쓸 수 있음.
class LayoutWeights {
  const LayoutWeights({
    this.largeMaxWidth = 0.45,
    this.normalMaxWidth = 0.32,
    this.minWidth = 0.18,
    this.fewPhotoCount = 6,
    this.fewPhotoCapBoost = 0.8,
    this.stackMinPhotos = 5,
    this.tierRatioMedium = 0.7,
    this.tierRatioSmall = 0.5,
    this.coverageMax = 0.8,
    this.maxOverlap = 0.18,
    this.edgeMargin = 0.025,
    this.maxHidden = 0.3,
    this.stackOffset = 0.3,
    this.protectedInset = 0.22,
    this.rotationMinDeg = 2,
    this.rotationMaxDeg = 6,
    this.rotationWideDeg = 8,
    this.rotationWideChance = 0.2,
    this.gridCols = 32,
    this.initialCandidates = 80,
    this.iterations = 1500,
    this.wCoverage = 4,
    this.wHole = 6,
    this.wOverlap = 20,
    this.wProtected = 12,
    this.wReserved = 60,
    this.wBalance = 1.5,
    this.wSameTierAdjacent = 0.08,
    this.wNearAlign = 0.05,
    this.isolationGap = 0.04,
    this.wIsolation = 3,
  });

  final double largeMaxWidth;
  final double normalMaxWidth;
  final double minWidth;

  /// 사진이 이 장수보다 적으면 크기 상한을 올림 (1장일 때 최대 +[fewPhotoCapBoost]).
  final int fewPhotoCount;
  final double fewPhotoCapBoost;

  /// 사진이 이보다 적으면 유사샷이어도 스택하지 않음.
  final int stackMinPhotos;
  final double tierRatioMedium;
  final double tierRatioSmall;
  final double coverageMax;
  final double maxOverlap;

  /// 캔버스 가장자리 여백.
  final double edgeMargin;

  /// 한 아이템이 위 아이템들에 가려진 총 비율 한도.
  final double maxHidden;

  /// 스택 뒤 사진이 리더 크기 대비 비껴 나오는 거리.
  final double stackOffset;
  final double protectedInset;
  final double rotationMinDeg;
  final double rotationMaxDeg;
  final double rotationWideDeg;
  final double rotationWideChance;
  final int gridCols;
  final int initialCandidates;
  final int iterations;
  final double wCoverage;
  final double wHole;
  final double wOverlap;
  final double wProtected;
  final double wReserved;
  final double wBalance;
  final double wSameTierAdjacent;
  final double wNearAlign;

  /// 가장 가까운 아이템과 이보다 멀면 감점.
  final double isolationGap;
  final double wIsolation;

  factory LayoutWeights.fromJson(Map<String, dynamic> json) {
    const d = LayoutWeights();
    double n(String k, double v) => (json[k] as num?)?.toDouble() ?? v;
    int i(String k, int v) => (json[k] as num?)?.toInt() ?? v;
    return LayoutWeights(
      largeMaxWidth: n('largeMaxWidth', d.largeMaxWidth),
      normalMaxWidth: n('normalMaxWidth', d.normalMaxWidth),
      minWidth: n('minWidth', d.minWidth),
      fewPhotoCount: i('fewPhotoCount', d.fewPhotoCount),
      fewPhotoCapBoost: n('fewPhotoCapBoost', d.fewPhotoCapBoost),
      stackMinPhotos: i('stackMinPhotos', d.stackMinPhotos),
      tierRatioMedium: n('tierRatioMedium', d.tierRatioMedium),
      tierRatioSmall: n('tierRatioSmall', d.tierRatioSmall),
      coverageMax: n('coverageMax', d.coverageMax),
      maxOverlap: n('maxOverlap', d.maxOverlap),
      edgeMargin: n('edgeMargin', d.edgeMargin),
      maxHidden: n('maxHidden', d.maxHidden),
      stackOffset: n('stackOffset', d.stackOffset),
      protectedInset: n('protectedInset', d.protectedInset),
      rotationMinDeg: n('rotationMinDeg', d.rotationMinDeg),
      rotationMaxDeg: n('rotationMaxDeg', d.rotationMaxDeg),
      rotationWideDeg: n('rotationWideDeg', d.rotationWideDeg),
      rotationWideChance: n('rotationWideChance', d.rotationWideChance),
      gridCols: i('gridCols', d.gridCols),
      initialCandidates: i('initialCandidates', d.initialCandidates),
      iterations: i('iterations', d.iterations),
      wCoverage: n('wCoverage', d.wCoverage),
      wHole: n('wHole', d.wHole),
      wOverlap: n('wOverlap', d.wOverlap),
      wProtected: n('wProtected', d.wProtected),
      wReserved: n('wReserved', d.wReserved),
      wBalance: n('wBalance', d.wBalance),
      wSameTierAdjacent: n('wSameTierAdjacent', d.wSameTierAdjacent),
      wNearAlign: n('wNearAlign', d.wNearAlign),
      isolationGap: n('isolationGap', d.isolationGap),
      wIsolation: n('wIsolation', d.wIsolation),
    );
  }
}

/// 목표 커버리지. 아이템이 적으면 억지로 채우지 않고 여백 허용.
double targetCoverageFor(int itemCount, LayoutWeights weights) =>
    math.min(weights.coverageMax, 0.25 + 0.1 * itemCount);

LayoutResult autoLayout(
  List<LayoutItem> items,
  LayoutCanvas canvas, {
  int seed = 0,
  LayoutWeights weights = const LayoutWeights(),
}) {
  final engine = _Engine(items, canvas, weights, math.Random(seed));
  final placements = engine.run();
  return LayoutResult(
    placements: placements,
    energy: engine.bestEnergy,
    metrics: measureLayout(
      items,
      placements,
      canvas,
      weights: weights,
      targetCoverage: engine.target,
    ),
    seed: seed,
  );
}

/// 시드를 바꿔 여러 안을 만들고 점수 순으로 정렬 (스와이프 후보용).
List<LayoutResult> autoLayoutCandidates(
  List<LayoutItem> items,
  LayoutCanvas canvas, {
  int count = 3,
  int seed = 0,
  LayoutWeights weights = const LayoutWeights(),
}) {
  final results = [
    for (var s = seed; s < seed + count; s++)
      autoLayout(items, canvas, seed: s, weights: weights),
  ]..sort((a, b) => a.energy.compareTo(b.energy));
  return results;
}

LayoutMetrics measureLayout(
  List<LayoutItem> items,
  List<LayoutPlacement> placements,
  LayoutCanvas canvas, {
  LayoutWeights weights = const LayoutWeights(),
  double? targetCoverage,
}) {
  final byId = {for (final it in items) it.id: it};
  final states = [
    for (final p in placements)
      _State(byId[p.id]!, p.tier)
        ..stackKey =
            p.stackOf ??
            (placements.any((q) => q.stackOf == p.id) ? p.id : null)
        ..cx = p.cx
        ..cy = p.cy
        ..w = p.width
        ..h = p.height
        ..rot = p.rotation
        ..z = p.z,
  ];
  final grid = _Grid(canvas, weights.gridCols);
  final canvasPoly = _rectPoly(LayoutRect(0, 0, 1, canvas.aspect));

  double maxOverlap = 0;
  for (var i = 0; i < states.length; i++) {
    for (var j = i + 1; j < states.length; j++) {
      final a = states[i], b = states[j];
      if (_sameStack(a, b)) continue;
      final ov = _intersectionArea(a.poly, b.poly);
      maxOverlap = math.max(maxOverlap, ov / math.min(a.area, b.area));
    }
  }
  double out = 0, reserved = 0;
  for (final s in states) {
    out += s.area - _intersectionArea(s.poly, canvasPoly);
    for (final r in canvas.reserved) {
      reserved += _intersectionArea(s.poly, _rectPoly(r));
    }
  }
  double occlusion = 0, hidden = 0;
  for (final s in states) {
    occlusion = math.max(occlusion, _protectedOcclusion(s, states, weights));
    hidden = math.max(hidden, _hiddenFraction(s, states));
  }
  final cov = grid.measure(states);
  return LayoutMetrics(
    coverage: cov.coverage,
    targetCoverage: targetCoverage ?? targetCoverageFor(items.length, weights),
    largestHole: cov.largestHole,
    maxOverlap: maxOverlap,
    outOfCanvas: out,
    reservedIntrusion: reserved,
    maxProtectedOcclusion: occlusion,
    maxHidden: hidden,
  );
}

// ─── 내부 구현 ────────────────────────────────────────────────

class _Pt {
  const _Pt(this.x, this.y);
  final double x;
  final double y;
}

class _State {
  _State(this.item, this.tier);

  final LayoutItem item;
  int tier;
  double cx = 0, cy = 0, w = 0, h = 0, rot = 0;

  /// 티어 기준 폭(크기 미세조정은 이 값의 ±12% 안에서만).
  double baseW = 0;

  /// 크기 상한(티어별 폭 상한 + 세로 길이 상한을 폭으로 환산).
  double maxW = double.infinity;

  /// 유저가 고정한 아이템 (배치/국소 개선에서 움직이지 않음).
  bool pinned = false;

  /// 스택 뒤 사진이면 앞 사진. 오프셋은 리더 폭/높이 비율.
  _State? leader;
  double offX = 0, offY = 0;

  /// 같은 스택이면 같은 값(리더 id). 스택 안 된 사진은 null.
  String? stackKey;
  int z = 0;

  double get area => w * h;

  List<_Pt> get poly => _rotRect(cx, cy, w, h, rot);

  /// 아이템 내부 좌표(0~1)를 캔버스 좌표로.
  _Pt toCanvas(double u, double v) {
    final lx = (u - 0.5) * w, ly = (v - 0.5) * h;
    final c = math.cos(rot), s = math.sin(rot);
    return _Pt(cx + lx * c - ly * s, cy + lx * s + ly * c);
  }

  bool contains(double px, double py) {
    final dx = px - cx, dy = py - cy;
    final c = math.cos(rot), s = math.sin(rot);
    final lx = dx * c + dy * s, ly = -dx * s + dy * c;
    return lx.abs() <= w / 2 && ly.abs() <= h / 2;
  }

  /// 회전 적용 후 축 정렬 바운딩 박스 절반 크기.
  double get halfAabbW =>
      (w * math.cos(rot).abs() + h * math.sin(rot).abs()) / 2;
  double get halfAabbH =>
      (w * math.sin(rot).abs() + h * math.cos(rot).abs()) / 2;

  _State copy() => _State(item, tier)
    ..cx = cx
    ..cy = cy
    ..w = w
    ..h = h
    ..rot = rot
    ..baseW = baseW
    ..maxW = maxW
    ..offX = offX
    ..offY = offY
    ..stackKey = stackKey
    ..pinned = pinned
    ..z = z;
}

List<_Pt> _rotRect(double cx, double cy, double w, double h, double rot) {
  final c = math.cos(rot), s = math.sin(rot);
  _Pt p(double lx, double ly) =>
      _Pt(cx + lx * c - ly * s, cy + lx * s + ly * c);
  return [
    p(-w / 2, -h / 2),
    p(w / 2, -h / 2),
    p(w / 2, h / 2),
    p(-w / 2, h / 2),
  ];
}

List<_Pt> _rectPoly(LayoutRect r) => [
  _Pt(r.left, r.top),
  _Pt(r.right, r.top),
  _Pt(r.right, r.bottom),
  _Pt(r.left, r.bottom),
];

double _signedArea(List<_Pt> p) {
  double a = 0;
  for (var i = 0; i < p.length; i++) {
    final q = p[i], r = p[(i + 1) % p.length];
    a += q.x * r.y - r.x * q.y;
  }
  return a / 2;
}

/// 볼록 다각형 교집합 면적 (Sutherland-Hodgman).
double _intersectionArea(List<_Pt> subject, List<_Pt> clip) {
  final sign = _signedArea(clip) >= 0 ? 1.0 : -1.0;
  var out = subject;
  for (var i = 0; i < clip.length && out.isNotEmpty; i++) {
    final a = clip[i], b = clip[(i + 1) % clip.length];
    double side(_Pt p) =>
        sign * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x));
    final input = out;
    out = [];
    for (var j = 0; j < input.length; j++) {
      final cur = input[j], prev = input[(j + input.length - 1) % input.length];
      final sc = side(cur), sp = side(prev);
      if (sc >= 0) {
        if (sp < 0) out.add(_lerpAt(prev, cur, sp / (sp - sc)));
        out.add(cur);
      } else if (sp >= 0) {
        out.add(_lerpAt(prev, cur, sp / (sp - sc)));
      }
    }
  }
  return out.length < 3 ? 0 : _signedArea(out).abs();
}

_Pt _lerpAt(_Pt a, _Pt b, double t) =>
    _Pt(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);

/// 보호 영역: 얼굴이 있으면 얼굴, 없으면 가운데(가장자리 띠만 겹침 허용).
List<List<_Pt>> _protectedPolys(_State s, LayoutWeights weights) {
  final regions = s.item.faces.isNotEmpty
      ? s.item.faces
      : [
          LayoutRect(
            weights.protectedInset,
            weights.protectedInset,
            1 - weights.protectedInset,
            1 - weights.protectedInset,
          ),
        ];
  return [
    for (final r in regions)
      [
        s.toCanvas(r.left, r.top),
        s.toCanvas(r.right, r.top),
        s.toCanvas(r.right, r.bottom),
        s.toCanvas(r.left, r.bottom),
      ],
  ];
}

bool _sameStack(_State a, _State b) =>
    a.stackKey != null && a.stackKey == b.stackKey;

/// [s]의 보호 영역 중 z가 더 높은 아이템에 가려진 비율(겹쳐 가린 경우 과대 추정 가능).
double _protectedOcclusion(_State s, List<_State> all, LayoutWeights weights) {
  double worst = 0;
  for (final poly in _protectedPolys(s, weights)) {
    final area = _signedArea(poly).abs();
    if (area <= 0) continue;
    double covered = 0;
    for (final o in all) {
      if (identical(o, s) || o.z <= s.z || _sameStack(o, s)) continue;
      if ((o.cx - s.cx).abs() > o.halfAabbW + s.halfAabbW ||
          (o.cy - s.cy).abs() > o.halfAabbH + s.halfAabbH) {
        continue;
      }
      covered += _intersectionArea(poly, o.poly);
    }
    worst = math.max(worst, math.min(1, covered / area));
  }
  return worst;
}

/// [s] 면적 중 z가 더 높은 아이템에 가려진 비율 (겹친 부분은 중복 합산될 수 있음).
double _hiddenFraction(_State s, List<_State> all) {
  final poly = s.poly;
  double covered = 0;
  for (final o in all) {
    if (identical(o, s) || o.z <= s.z || _sameStack(o, s)) continue;
    if ((o.cx - s.cx).abs() > o.halfAabbW + s.halfAabbW ||
        (o.cy - s.cy).abs() > o.halfAabbH + s.halfAabbH) {
      continue;
    }
    covered += _intersectionArea(poly, o.poly);
  }
  return math.min(1, covered / s.area);
}

class _Coverage {
  const _Coverage(this.coverage, this.largestHole, this.cx, this.cy);
  final double coverage;
  final double largestHole;

  /// 가용 영역 중심(무게중심 균형 기준점).
  final double cx;
  final double cy;
}

/// 점유 맵. 셀 중심이 아이템 안에 있으면 덮인 것으로 봄.
class _Grid {
  _Grid(this.canvas, this.cols)
    : rows = (cols * canvas.aspect).ceil(),
      cell = 1 / cols {
    available = List.filled(cols * rows, true);
    double sx = 0, sy = 0;
    var n = 0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final x = (c + 0.5) * cell, y = (r + 0.5) * cell;
        final ok =
            y <= canvas.aspect &&
            !canvas.reserved.any(
              (q) => x >= q.left && x <= q.right && y >= q.top && y <= q.bottom,
            );
        available[r * cols + c] = ok;
        if (ok) {
          sx += x;
          sy += y;
          n++;
        }
      }
    }
    availableCount = n;
    centerX = n == 0 ? 0.5 : sx / n;
    centerY = n == 0 ? canvas.aspect / 2 : sy / n;
  }

  final LayoutCanvas canvas;
  final int cols;
  final int rows;
  final double cell;
  late final List<bool> available;
  late final int availableCount;
  late final double centerX;
  late final double centerY;

  _Coverage measure(List<_State> states) {
    final covered = List.filled(cols * rows, false);
    for (final s in states) {
      final c0 = ((s.cx - s.halfAabbW) / cell).floor().clamp(0, cols - 1);
      final c1 = ((s.cx + s.halfAabbW) / cell).ceil().clamp(0, cols - 1);
      final r0 = ((s.cy - s.halfAabbH) / cell).floor().clamp(0, rows - 1);
      final r1 = ((s.cy + s.halfAabbH) / cell).ceil().clamp(0, rows - 1);
      for (var r = r0; r <= r1; r++) {
        for (var c = c0; c <= c1; c++) {
          final i = r * cols + c;
          if (covered[i]) continue;
          if (s.contains((c + 0.5) * cell, (r + 0.5) * cell)) covered[i] = true;
        }
      }
    }
    var hit = 0;
    // 가장 큰 빈 정사각형 (DP).
    final dp = List.filled(cols * rows, 0);
    var best = 0;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final i = r * cols + c;
        if (!available[i]) continue;
        if (covered[i]) {
          hit++;
          continue;
        }
        final up = r > 0 ? dp[i - cols] : 0;
        final left = c > 0 ? dp[i - 1] : 0;
        final diag = r > 0 && c > 0 ? dp[i - cols - 1] : 0;
        dp[i] = 1 + math.min(up, math.min(left, diag));
        if (dp[i] > best) best = dp[i];
      }
    }
    return _Coverage(
      availableCount == 0 ? 0 : hit / availableCount,
      best * cell,
      centerX,
      centerY,
    );
  }
}

class _Engine {
  _Engine(this.items, this.canvas, this.weights, this.rng)
    : grid = _Grid(canvas, weights.gridCols),
      target = targetCoverageFor(items.length, weights),
      // 폭 전체를 가로지르는 예약 영역(제목 띠)은 감점이 아니라 위치 보정으로 막음.
      topBand = canvas.reserved
          .where((r) => r.left <= 0 && r.right >= 1 && r.top <= 0)
          .fold(0.0, (v, r) => math.max(v, r.bottom)),
      // 아래쪽 편집 도구 줄처럼 폭 전체 + 바닥까지 닿는 예약 영역도 같은 방식.
      bottomBand = canvas.reserved
          .where(
            (r) => r.left <= 0 && r.right >= 1 && r.bottom >= canvas.aspect,
          )
          .fold(canvas.aspect, (v, r) => math.min(v, r.top));

  final List<LayoutItem> items;
  final LayoutCanvas canvas;
  final LayoutWeights weights;
  final math.Random rng;
  final _Grid grid;
  final double topBand;
  final double bottomBand;

  /// 크기 상한 때문에 도달 못 하는 목표는 [_sizeItems]에서 낮춤.
  double target;
  double bestEnergy = double.infinity;

  List<LayoutPlacement> run() {
    if (items.isEmpty) {
      bestEnergy = 0;
      return const [];
    }
    final states = _sizeItems();
    _assignZ(states);
    _initialPlace(states);
    final best = _anneal(states);
    _repairOverlaps(best);
    _syncFollowers(best);
    return [
      for (final s in best)
        LayoutPlacement(
          id: s.item.id,
          cx: s.cx,
          cy: s.cy,
          width: s.w,
          height: s.h,
          rotation: s.rot,
          z: s.z,
          tier: s.tier,
          stackOf: s.leader?.item.id,
        ),
    ];
  }

  // ① 크기: 화질 순위로 대·중·소, 목표 커버리지에 맞춰 전체 배율 결정.
  List<_State> _sizeItems() {
    // 스택마다 화질 제일 좋은 사진이 리더, 나머지는 뒤에 깔림.
    final leaderOf = <String, LayoutItem>{};
    final photoCount = items
        .where((i) => i.kind == LayoutItemKind.photo)
        .length;
    for (final it in items) {
      final g = it.stackGroup;
      if (it.kind != LayoutItemKind.photo || g == null) continue;
      if (photoCount < weights.stackMinPhotos) continue;
      final cur = leaderOf[g];
      if (cur == null || it.quality > cur.quality) leaderOf[g] = it;
    }
    bool isFollower(LayoutItem it) =>
        leaderOf[it.stackGroup] != null &&
        !identical(leaderOf[it.stackGroup], it);
    final followerCount = items.where(isFollower).length;
    // 뒤 사진은 일부만 보이므로 목표 커버리지 계산에서 0.4장으로 셈.
    target = targetCoverageFor(
      (items.length - followerCount * 0.6).round(),
      weights,
    );

    final photos =
        items
            .where(
              (i) =>
                  i.kind == LayoutItemKind.photo &&
                  !isFollower(i) &&
                  i.pin == null,
            )
            .toList()
          ..sort((a, b) => b.quality.compareTo(a.quality));
    final nLarge = photos.isEmpty ? 0 : (photos.length >= 7 ? 2 : 1);
    final nMedium = ((photos.length - nLarge) * 0.4).round();
    final tierOf = <String, int>{
      for (var i = 0; i < photos.length; i++)
        photos[i].id: i < nLarge ? 0 : (i < nLarge + nMedium ? 1 : 2),
    };
    final ratio = [1.0, weights.tierRatioMedium, weights.tierRatioSmall];

    final availArea = grid.availableCount * grid.cell * grid.cell;
    // 겹침으로 잃는 면적만큼 약간 여유 있게 잡음.
    final wantArea = target * availArea * 1.08;
    double fixedArea = 0;
    for (final it in items) {
      final fw = it.pin?.width ?? it.fixedWidth;
      if (fw != null) fixedArea += fw * fw / it.aspect;
    }

    // 사진이 적으면 상한을 올려서 여백이 휑하지 않게 (1장 +50% ~ fewPhotoCount장 이상 0%).
    final few = weights.fewPhotoCount;
    final boost =
        1 +
        weights.fewPhotoCapBoost *
            ((few - photos.length) / math.max(1, few - 1)).clamp(0.0, 1.0);
    double capFor(int tier) =>
        (tier == 0 ? weights.largeMaxWidth : weights.normalMaxWidth) * boost;

    // 상한/하한은 3:4 세로 사진 폭 기준 값을 면적(= side²)으로 환산해서 적용,
    // 아주 긴 세로 사진(9:16)은 높이 상한으로 따로 제한.
    final ref = math.sqrt(3 / 4);
    double sideCap(int tier) => capFor(tier) / ref;
    double maxWidthFor(LayoutItem it, int tier) => math.min(
      math.min(
        sideCap(tier) * math.sqrt(it.aspect),
        // 회전(최대 8°)해도 캔버스 폭 안에 들어오도록 여유.
        0.85 - 2 * weights.edgeMargin,
      ),
      capFor(tier) * 1.35 * it.aspect,
    );

    double widthFor(LayoutItem it, int tier, double side) {
      // side = 면적의 제곱근 → 세로/가로 사진이 비슷한 무게로 보이게.
      final s = (side * ratio[tier]).clamp(
        weights.minWidth / ref,
        sideCap(tier),
      );
      return math.min(s * math.sqrt(it.aspect), maxWidthFor(it, tier));
    }

    // 면적 합이 목표에 맞는 side를 이분 탐색.
    double lo = 0.05, hi = 1.0;
    for (var k = 0; k < 30; k++) {
      final mid = (lo + hi) / 2;
      double area = fixedArea;
      for (final p in photos) {
        final w = widthFor(p, tierOf[p.id]!, mid);
        area += w * w / p.aspect;
      }
      final small = mid * weights.tierRatioSmall;
      area += followerCount * 0.4 * small * small;
      if (area < wantArea) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final side = lo;
    if (lo > 0.99) {
      // 상한에 막혀 목표 면적에 못 미침 → 목표를 낮추고 여백 허용.
      double area = fixedArea;
      for (final p in photos) {
        final w = widthFor(p, tierOf[p.id]!, side);
        area += w * w / p.aspect;
      }
      target = math.min(target, area / availArea / 1.08);
    }

    final states = [
      for (final it in items.where((i) => !isFollower(i)))
        () {
          final pin = it.pin;
          if (pin != null) {
            // 고정 사진은 티어 비교 대상이 아니라 중간 티어로 취급 (z 순서용).
            return _State(it, it.kind == LayoutItemKind.photo ? 1 : -1)
              ..w = pin.width
              ..h = pin.width / it.aspect
              ..baseW = pin.width
              ..maxW = pin.width
              ..cx = pin.cx
              ..cy = pin.cy
              ..rot = pin.rotation
              ..pinned = true;
          }
          final tier = it.kind == LayoutItemKind.photo ? tierOf[it.id]! : -1;
          final w = it.fixedWidth ?? widthFor(it, tier < 0 ? 1 : tier, side);
          return _State(it, tier)
            ..w = w
            ..h = w / it.aspect
            ..baseW = w
            ..maxW = it.fixedWidth ?? maxWidthFor(it, tier < 0 ? 1 : tier);
        }(),
    ];
    final byId = {for (final s in states) s.item.id: s};
    for (final l in leaderOf.values) {
      if (items.any((i) => isFollower(i) && i.stackGroup == l.stackGroup)) {
        byId[l.id]!.stackKey = l.id;
      }
    }
    final angleOf = <String, double>{};
    final countOf = <String, int>{};
    for (final it in items.where(isFollower)) {
      final l = byId[leaderOf[it.stackGroup]!.id]!;
      // 리더 면적의 80%.
      final w = math.sqrt(l.area * 0.8 * it.aspect);
      final f = _State(it, l.tier)
        ..w = w
        ..h = w / it.aspect
        ..baseW = w
        ..maxW = w
        ..leader = l
        ..stackKey = l.item.id;
      final g = it.stackGroup!;
      final base = angleOf.putIfAbsent(g, () => rng.nextDouble() * 2 * math.pi);
      final k = countOf[g] = (countOf[g] ?? -1) + 1;
      _rollStackOffset(f, base, k);
      states.add(f);
    }
    return states;
  }

  // z: 소 < 중 < 대 < 포스터. 스택 뒤 사진은 리더 바로 아래.
  void _assignZ(List<_State> states) {
    int rank(_State s) => switch (s.item.kind) {
      LayoutItemKind.poster => 90,
      LayoutItemKind.photo => 10 * (3 - s.tier),
    };
    final order = states.where((s) => s.leader == null).toList()..shuffle(rng);
    order.sort((a, b) => rank(a).compareTo(rank(b)));
    var z = 0;
    for (final s in order) {
      for (final f in states.where((f) => identical(f.leader, s))) {
        f.z = z++;
      }
      s.z = z++;
    }
  }

  double _randomRotation(LayoutItem it) {
    final sign = rng.nextBool() ? 1 : -1;
    final double deg;
    if (it.kind != LayoutItemKind.photo) {
      deg = rng.nextDouble() * 3;
    } else if (rng.nextDouble() < weights.rotationWideChance) {
      deg =
          weights.rotationMaxDeg +
          rng.nextDouble() * (weights.rotationWideDeg - weights.rotationMaxDeg);
    } else {
      deg =
          weights.rotationMinDeg +
          rng.nextDouble() * (weights.rotationMaxDeg - weights.rotationMinDeg);
    }
    return sign * deg * math.pi / 180;
  }

  /// 회전된 바운딩 박스가 캔버스 안에 들어오도록 중심 보정 (`_clampToCanvas`와 같은 방식).
  void _clamp(_State s) {
    final m = weights.edgeMargin;
    final hw = s.halfAabbW + m, hh = s.halfAabbH + m;
    s.cx = hw * 2 >= 1 ? 0.5 : s.cx.clamp(hw, 1 - hw);
    final top = topBand + hh, bottom = bottomBand - hh;
    s.cy = top >= bottom ? (topBand + bottomBand) / 2 : s.cy.clamp(top, bottom);
  }

  // ② 초기 배치: 큰 것부터, 빈 곳 주변 후보 위치 중 점수 좋은 곳.
  void _initialPlace(List<_State> states) {
    int order(_State s) => switch (s.item.kind) {
      LayoutItemKind.poster => 0,
      LayoutItemKind.photo => s.tier == 0 ? 1 : 2,
    };
    // 스택 뒤 사진은 리더를 따라가므로 따로 배치하지 않음.
    final queue = states.where((s) => s.leader == null && !s.pinned).toList()
      ..sort((a, b) {
        final o = order(a).compareTo(order(b));
        return o != 0 ? o : b.area.compareTo(a.area);
      });
    final placed = <_State>[...states.where((s) => s.pinned)];
    for (final s in queue) {
      _State? best;
      var bestE = double.infinity;
      for (var k = 0; k < weights.initialCandidates; k++) {
        final c = s.copy()..rot = _randomRotation(s.item);
        if (k.isEven || placed.isEmpty) {
          c.cx = rng.nextDouble();
          c.cy = rng.nextDouble() * canvas.aspect;
        } else {
          final spot = _randomEmptySpot(placed);
          c.cx = spot.x + (rng.nextDouble() - 0.5) * c.w * 0.5;
          c.cy = spot.y + (rng.nextDouble() - 0.5) * c.h * 0.5;
        }
        _clamp(c);
        final e = _energy([...placed, c], partial: true);
        if (e < bestE) {
          bestE = e;
          best = c;
        }
      }
      s
        ..cx = best!.cx
        ..cy = best.cy
        ..rot = best.rot;
      placed.add(s);
      final followers = states.where((f) => identical(f.leader, s)).toList();
      _syncFollowers(followers);
      placed.addAll(followers);
    }
  }

  /// 스택 뒤 사진을 리더 기준 오프셋 위치로.
  void _syncFollowers(Iterable<_State> states) {
    for (final f in states) {
      final l = f.leader;
      if (l == null) continue;
      f.cx = l.cx + f.offX * l.w;
      f.cy = l.cy + f.offY * l.h;
      _clamp(f);
    }
  }

  /// 리더 뒤로 비껴 나오는 방향. 뒤 사진끼리는 60° 이상 벌려서 부채꼴처럼.
  void _rollStackOffset(_State f, double baseAngle, int k) {
    final a = baseAngle + k * math.pi / 3 + (rng.nextDouble() - 0.5) * 0.5;
    f.offX = math.cos(a) * weights.stackOffset;
    f.offY = math.sin(a) * weights.stackOffset;
  }

  _Pt _randomEmptySpot(List<_State> placed) {
    for (var t = 0; t < 30; t++) {
      final x = rng.nextDouble(), y = rng.nextDouble() * canvas.aspect;
      final r = (y / grid.cell).floor().clamp(0, grid.rows - 1);
      final c = (x / grid.cell).floor().clamp(0, grid.cols - 1);
      if (!grid.available[r * grid.cols + c]) continue;
      if (placed.every((s) => !s.contains(x, y))) return _Pt(x, y);
    }
    return _Pt(rng.nextDouble(), rng.nextDouble() * canvas.aspect);
  }

  // ③ 국소 개선: 옮기기 / 회전 / 맞바꾸기 / 크기 미세조정, 담금질로 가끔 나빠지는 것도 허용.
  List<_State> _anneal(List<_State> states) {
    var cur = states;
    var curE = _energy(cur);
    var best = _copyAll(cur);
    bestEnergy = curE;
    final n = weights.iterations;
    const t0 = 0.05, t1 = 0.0005;
    for (var it = 0; it < n; it++) {
      final progress = it / n;
      final temp = t0 * math.pow(t1 / t0, progress);
      final next = _copyAll(cur);
      final roll = rng.nextDouble();
      final movable = next.where((s) => !s.pinned).toList();
      if (movable.isEmpty) break;
      final a = movable[rng.nextInt(movable.length)];
      final photos = movable
          .where((s) => s.item.kind == LayoutItemKind.photo && s.leader == null)
          .toList();
      if (a.leader != null) {
        // 스택 뒤 사진: 비껴 나오는 방향이나 기울기만 바꿈.
        if (roll < 0.5) {
          _rollStackOffset(a, rng.nextDouble() * 2 * math.pi, 0);
        } else {
          a.rot = _randomRotation(a.item);
        }
      } else if (roll < 0.5) {
        final sigma = 0.08 * (1 - progress) + 0.01;
        a.cx += _gauss() * sigma;
        a.cy += _gauss() * sigma;
      } else if (roll < 0.65) {
        a.rot = _randomRotation(a.item);
      } else if (roll < 0.85 && photos.length >= 2) {
        final p = photos[rng.nextInt(photos.length)];
        final q = photos[rng.nextInt(photos.length)];
        final tx = p.cx, ty = p.cy;
        p
          ..cx = q.cx
          ..cy = q.cy;
        q
          ..cx = tx
          ..cy = ty;
        _clamp(q);
      } else if (a.item.kind == LayoutItemKind.photo) {
        final f = 0.88 + rng.nextDouble() * 0.24;
        a.w = math.min(a.baseW * f, a.maxW);
        a.h = a.w / a.item.aspect;
      }
      if (a.leader == null) _clamp(a);
      for (final p in photos) {
        _clamp(p);
      }
      _syncFollowers(next);
      final e = _energy(next);
      if (e < curE || rng.nextDouble() < math.exp(-(e - curE) / temp)) {
        cur = next;
        curE = e;
        if (e < bestEnergy) {
          bestEnergy = e;
          best = _copyAll(cur);
        }
      }
    }
    return best;
  }

  /// 복사하면서 스택 리더 참조도 새 복사본으로 연결.
  List<_State> _copyAll(List<_State> states) {
    final copies = [for (final s in states) s.copy()];
    final map = <_State, _State>{
      for (var i = 0; i < states.length; i++) states[i]: copies[i],
    };
    for (var i = 0; i < states.length; i++) {
      final l = states[i].leader;
      if (l != null) copies[i].leader = map[l];
    }
    return copies;
  }

  /// ④ 마무리 보정: 겹침 한도를 넘는 쌍이 남으면 움직일 수 있는 쪽만 밀어내거나 살짝 줄임.
  void _repairOverlaps(List<_State> states) {
    final limit = weights.maxOverlap + 0.005;
    double ratio(_State a, _State b) =>
        _intersectionArea(a.poly, b.poly) / math.min(a.area, b.area);

    for (var round = 0; round < 60; round++) {
      _State? a, b;
      var worst = limit;
      for (var i = 0; i < states.length; i++) {
        for (var j = i + 1; j < states.length; j++) {
          if (_sameStack(states[i], states[j])) continue;
          final r = ratio(states[i], states[j]);
          if (r > worst) {
            worst = r;
            a = states[i];
            b = states[j];
          }
        }
      }
      if (a == null || b == null) return;
      // 고정 아닌 쪽, 둘 다 움직일 수 있으면 작은 쪽을 움직임.
      final move = a.pinned || (!b.pinned && b.area < a.area) ? b : a;
      final other = identical(move, a) ? b : a;
      if (move.pinned || move.leader != null) return;

      var dx = move.cx - other.cx, dy = move.cy - other.cy;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 1e-6) {
        dx = 1;
        dy = 0;
      } else {
        dx /= len;
        dy /= len;
      }
      final index = states.indexOf(move);
      // 8방향 모두 시도 (반대 방향 제외).
      final dirs =
          [
            for (var k = 0; k < 8; k++)
              (math.cos(k * math.pi / 4), math.sin(k * math.pi / 4)),
          ]..sort(
            (p, q) => (q.$1 * dx + q.$2 * dy).compareTo(p.$1 * dx + p.$2 * dy),
          );
      _State? bestMove;
      var bestE = double.infinity;
      for (final (ux, uy) in dirs.take(6)) {
        for (final step in const [0.02, 0.05, 0.1, 0.16, 0.24]) {
          for (final shrink in const [1.0, 0.92, 0.85]) {
            final c = move.copy()
              ..cx = move.cx + ux * step
              ..cy = move.cy + uy * step
              ..w = move.w * shrink;
            c.h = c.w / c.item.aspect;
            _clamp(c);
            if (ratio(c, other) > limit) continue;
            states[index] = c;
            final e = _energy(states);
            states[index] = move;
            if (e < bestE) {
              bestE = e;
              bestMove = c;
            }
          }
        }
      }
      if (bestMove == null) return;
      move
        ..cx = bestMove.cx
        ..cy = bestMove.cy
        ..w = bestMove.w
        ..h = bestMove.h;
    }
  }

  double _gauss() {
    final u1 = math.max(rng.nextDouble(), 1e-12), u2 = rng.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  /// 총점(낮을수록 좋음). [partial]이면 초기 배치 중이라 커버리지는 최대화만.
  double _energy(List<_State> states, {bool partial = false}) {
    final cov = grid.measure(states);
    var e = 0.0;

    if (partial) {
      e -= weights.wCoverage * cov.coverage;
    } else {
      e += weights.wCoverage * math.max(0, target - cov.coverage);
      e += weights.wCoverage * 0.5 * math.max(0, cov.coverage - (target + 0.1));
      final holeLimit = 0.2 + (weights.coverageMax - target) * 0.8;
      e += weights.wHole * math.max(0, cov.largestHole - holeLimit);
    }

    double wsum = 0, wx = 0, wy = 0;
    for (var i = 0; i < states.length; i++) {
      final a = states[i];
      final pa = a.poly;
      wsum += a.area;
      wx += a.cx * a.area;
      wy += a.cy * a.area;
      for (final r in canvas.reserved) {
        e += weights.wReserved * _intersectionArea(pa, _rectPoly(r)) / a.area;
      }
      for (var j = i + 1; j < states.length; j++) {
        final b = states[j];
        if (_sameStack(a, b)) continue;
        // 멀리 떨어진 쌍은 계산 생략.
        if ((a.cx - b.cx).abs() > a.halfAabbW + b.halfAabbW + 0.03 ||
            (a.cy - b.cy).abs() > a.halfAabbH + b.halfAabbH + 0.03) {
          continue;
        }
        final ov = _intersectionArea(pa, b.poly) / math.min(a.area, b.area);
        e += weights.wOverlap * math.max(0, ov - weights.maxOverlap);
        if (a.tier >= 0 && a.tier == b.tier) e += weights.wSameTierAdjacent;
        e += weights.wNearAlign * _nearAlignCount(a, b);
      }
      e += weights.wProtected * _protectedOcclusion(a, states, weights);
      if (!partial && states.length > 1) {
        var nearest = double.infinity;
        for (final b in states) {
          if (identical(a, b)) continue;
          final dx = math.max(
            0.0,
            (a.cx - b.cx).abs() - a.halfAabbW - b.halfAabbW,
          );
          final dy = math.max(
            0.0,
            (a.cy - b.cy).abs() - a.halfAabbH - b.halfAabbH,
          );
          nearest = math.min(nearest, math.sqrt(dx * dx + dy * dy));
        }
        e += weights.wIsolation * math.max(0, nearest - weights.isolationGap);
      }
      e +=
          weights.wOverlap *
          math.max(0, _hiddenFraction(a, states) - weights.maxHidden);
    }

    if (!partial && wsum > 0) {
      final dx = wx / wsum - cov.cx, dy = wy / wsum - cov.cy;
      e += weights.wBalance * math.sqrt(dx * dx + dy * dy);
    }
    return e;
  }

  /// 가장자리가 몇 px 차이로 "거의" 맞는 경우.
  int _nearAlignCount(_State a, _State b) {
    const exact = 0.004, near = 0.02;
    final ea = [
      a.cx - a.halfAabbW,
      a.cx + a.halfAabbW,
      a.cy - a.halfAabbH,
      a.cy + a.halfAabbH,
    ];
    final eb = [
      b.cx - b.halfAabbW,
      b.cx + b.halfAabbW,
      b.cy - b.halfAabbH,
      b.cy + b.halfAabbH,
    ];
    var n = 0;
    for (var k = 0; k < 4; k++) {
      final d = (ea[k] - eb[k]).abs();
      if (d > exact && d < near) n++;
    }
    return n;
  }
}
