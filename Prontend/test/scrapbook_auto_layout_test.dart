import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/services/scrapbook_auto_layout.dart';

// 폰 세로 / 태블릿 세로 공연후 페이지 비율 + 상단 제목 영역.
const _phone = LayoutCanvas(
  aspect: 1.55,
  reserved: [LayoutRect(0, 0, 1, 0.12)],
);
const _tablet = LayoutCanvas(aspect: 1.3, reserved: [LayoutRect(0, 0, 1, 0.1)]);

const _poster = LayoutItem(
  id: 'poster',
  kind: LayoutItemKind.poster,
  aspect: 0.75,
  fixedWidth: 0.34,
);

/// 공연 사진처럼 가로/세로가 섞이고 일부는 얼굴이 있는 무작위 입력.
List<LayoutItem> _randomItems(math.Random r, int photos, {bool extras = true}) {
  const aspects = [4 / 3, 3 / 4, 16 / 9, 9 / 16, 1.0, 3 / 2, 2 / 3];
  return [
    if (extras) _poster,
    for (var i = 0; i < photos; i++)
      LayoutItem(
        id: 'p$i',
        kind: LayoutItemKind.photo,
        aspect: aspects[r.nextInt(aspects.length)],
        quality: r.nextDouble(),
        faces: r.nextDouble() < 0.4
            ? [
                LayoutRect(
                  0.3 + r.nextDouble() * 0.2,
                  0.15 + r.nextDouble() * 0.2,
                  0.55 + r.nextDouble() * 0.2,
                  0.45 + r.nextDouble() * 0.2,
                ),
              ]
            : const [],
      ),
  ];
}

void main() {
  test('빈 입력은 빈 결과', () {
    final result = autoLayout(const [], _phone);
    expect(result.placements, isEmpty);
  });

  test('같은 입력 + 같은 시드면 같은 결과, 시드가 다르면 다른 결과', () {
    final items = _randomItems(math.Random(1), 6);
    final a = autoLayout(items, _phone, seed: 3);
    final b = autoLayout(items, _phone, seed: 3);
    final c = autoLayout(items, _phone, seed: 4);
    expect(
      a.placements.map((p) => p.toJson()).toList(),
      b.placements.map((p) => p.toJson()).toList(),
    );
    expect(
      a.placements.map((p) => p.toJson()).toList(),
      isNot(c.placements.map((p) => p.toJson()).toList()),
    );
  });

  test('모든 아이템이 한 번씩 배치되고 포스터가 최상위 z', () {
    final items = _randomItems(math.Random(2), 9);
    final result = autoLayout(items, _tablet);
    expect(
      result.placements.map((p) => p.id).toSet(),
      items.map((i) => i.id).toSet(),
    );
    final zs = result.placements.map((p) => p.z).toSet();
    expect(zs.length, items.length);
    final top = result.placements.reduce((a, b) => a.z > b.z ? a : b);
    expect(top.id, 'poster');
  });

  test('무작위 입력 전반에서 품질 지표 유지 (7-3 회귀 기준)', () {
    const w = LayoutWeights();
    final r = math.Random(42);
    for (var k = 0; k < 40; k++) {
      final canvas = k.isEven ? _phone : _tablet;
      final photos = 1 + r.nextInt(15);
      final m = autoLayout(_randomItems(r, photos), canvas, seed: k).metrics;
      final reason = 'case $k photos=$photos $m';
      expect(m.outOfCanvas, lessThan(1e-9), reason: reason);
      expect(m.reservedIntrusion, lessThan(1e-9), reason: reason);
      expect(m.maxOverlap, lessThan(w.maxOverlap + 0.02), reason: reason);
      expect(m.maxHidden, lessThan(w.maxHidden + 0.03), reason: reason);
      expect(m.maxProtectedOcclusion, lessThan(0.05), reason: reason);
      // 장수가 적으면 긴 세로 사진(9:16) 조합에 따라 공간상 못 채우는 경우가 있어 오차를 넓게.
      final tolerance = photos < 8 ? 0.12 : 0.08;
      expect(
        m.coverage,
        greaterThan(m.targetCoverage - tolerance),
        reason: reason,
      );
      if (photos >= 10) expect(m.largestHole, lessThan(0.2), reason: reason);
    }
  });

  test('화질이 가장 좋은 사진이 가장 크게', () {
    final items = [
      for (var i = 0; i < 5; i++)
        LayoutItem(
          id: 'p$i',
          kind: LayoutItemKind.photo,
          aspect: 4 / 3,
          quality: i == 3 ? 0.95 : 0.2 + i * 0.1,
        ),
    ];
    final result = autoLayout(items, _phone);
    final biggest = result.placements.reduce(
      (a, b) => a.width * a.height >= b.width * b.height ? a : b,
    );
    expect(biggest.id, 'p3');
    expect(biggest.tier, 0);
  });

  test('회전 범위: 사진 ±8° 이내, 포스터 ±3° 이내', () {
    final result = autoLayout(_randomItems(math.Random(5), 12), _tablet);
    for (final p in result.placements) {
      final deg = p.rotation.abs() * 180 / math.pi;
      if (p.tier < 0) {
        expect(deg, lessThanOrEqualTo(3 + 1e-9), reason: p.id);
      } else {
        expect(deg, inInclusiveRange(2 - 1e-9, 8 + 1e-9), reason: p.id);
      }
    }
  });

  test('크기 상한 때문에 못 채우는 목표는 낮춰서 억지로 채우지 않음', () {
    final result = autoLayout(const [
      LayoutItem(id: 'p0', kind: LayoutItemKind.photo, aspect: 4 / 3),
    ], _phone);
    const w = LayoutWeights();
    expect(result.metrics.targetCoverage, lessThan(targetCoverageFor(1, w)));
    // 사진이 적으면 상한이 올라가지만 그 올라간 상한은 넘지 않음.
    expect(
      result.placements.single.width,
      lessThanOrEqualTo(w.largeMaxWidth * (1 + w.fewPhotoCapBoost) + 1e-9),
    );
  });

  test('원격 config JSON은 준 값만 덮어씀', () {
    final w = LayoutWeights.fromJson({'maxOverlap': 0.1, 'iterations': 300});
    const d = LayoutWeights();
    expect(w.maxOverlap, 0.1);
    expect(w.iterations, 300);
    expect(w.wCoverage, d.wCoverage);
    expect(w.largeMaxWidth, d.largeMaxWidth);
  });

  test('후보 안은 점수 순 정렬', () {
    final candidates = autoLayoutCandidates(
      _randomItems(math.Random(9), 6),
      _phone,
      count: 3,
    );
    expect(candidates, hasLength(3));
    for (var i = 1; i < candidates.length; i++) {
      expect(
        candidates[i].energy,
        greaterThanOrEqualTo(candidates[i - 1].energy),
      );
    }
  });

  test('유사샷 스택: 화질 좋은 사진이 앞, 나머지는 바로 뒤 z에 깔림', () {
    final items = [
      _poster,
      for (var i = 0; i < 6; i++)
        LayoutItem(
          id: 'p$i',
          kind: LayoutItemKind.photo,
          aspect: 3 / 4,
          quality: 0.1 * i,
          stackGroup: i >= 3 ? 'burst' : null,
        ),
    ];
    final result = autoLayout(items, _phone);
    final byId = {for (final p in result.placements) p.id: p};
    expect(byId['p5']!.stackOf, isNull, reason: '화질 제일 좋은 p5가 앞');
    for (final id in ['p3', 'p4']) {
      final f = byId[id]!;
      expect(f.stackOf, 'p5');
      expect(f.z, lessThan(byId['p5']!.z));
      // 뒤 사진은 리더 근처에 붙어 있음.
      final dx = (f.cx - byId['p5']!.cx).abs(),
          dy = (f.cy - byId['p5']!.cy).abs();
      expect(dx < byId['p5']!.width && dy < byId['p5']!.height, isTrue);
    }
    // 스택 밖 아이템끼리의 제약은 그대로 유지.
    final m = result.metrics;
    expect(m.outOfCanvas, lessThan(1e-9));
    expect(m.reservedIntrusion, lessThan(1e-9));
    expect(m.maxOverlap, lessThan(const LayoutWeights().maxOverlap + 0.02));
  });

  test('사진이 적을수록 크게 (여백이 휑하지 않게)', () {
    List<LayoutItem> photos(int n) => [
      for (var i = 0; i < n; i++)
        LayoutItem(
          id: 'p$i',
          kind: LayoutItemKind.photo,
          aspect: 4 / 3,
          quality: i / n,
        ),
    ];
    double largest(int n) => autoLayout(
      photos(n),
      _phone,
    ).placements.map((p) => p.width).reduce(math.max);
    expect(largest(3), greaterThan(const LayoutWeights().largeMaxWidth));
    expect(largest(3), greaterThan(largest(8)));
  });

  test('유저가 고정한 아이템은 그대로, 나머지는 그 주변에 배치', () {
    const pin = LayoutPin(cx: 0.3, cy: 0.5, width: 0.4, rotation: 0.05);
    final items = [
      _poster,
      const LayoutItem(
        id: 'pinned',
        kind: LayoutItemKind.photo,
        aspect: 4 / 3,
        pin: pin,
      ),
      for (var i = 0; i < 6; i++)
        LayoutItem(
          id: 'p$i',
          kind: LayoutItemKind.photo,
          aspect: i.isEven ? 4 / 3 : 3 / 4,
          quality: i / 6,
        ),
    ];
    for (final seed in [0, 1, 2]) {
      final result = autoLayout(items, _phone, seed: seed);
      final p = result.placements.firstWhere((p) => p.id == 'pinned');
      expect(p.cx, pin.cx);
      expect(p.cy, pin.cy);
      expect(p.width, pin.width);
      expect(p.rotation, pin.rotation);
      final m = result.metrics;
      expect(m.maxOverlap, lessThan(const LayoutWeights().maxOverlap + 0.02));
      expect(m.outOfCanvas, lessThan(1e-9));
    }
  });

  test('아래쪽 편집 도구 줄 영역(폭 전체 예약)은 절대 침범하지 않음', () {
    final r = math.Random(21);
    for (var k = 0; k < 20; k++) {
      final canvas = LayoutCanvas(
        aspect: 1.55,
        reserved: const [
          LayoutRect(0, 0, 1, 0.12),
          LayoutRect(0, 1.45, 1, 1.55),
        ],
      );
      final m = autoLayout(
        _randomItems(r, 1 + r.nextInt(14)),
        canvas,
        seed: k,
      ).metrics;
      expect(m.reservedIntrusion, lessThan(1e-9), reason: 'case $k $m');
      expect(m.outOfCanvas, lessThan(1e-9), reason: 'case $k $m');
    }
  });
}
