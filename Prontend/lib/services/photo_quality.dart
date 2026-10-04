import 'dart:math' as math;
import 'dart:typed_data';

/// 사진 화질 통계 (자동 배치 크기 티어 결정용, 순수 계산).
/// 입력은 긴 변 ~128px로 줄인 RGBA 픽셀.
class PhotoStats {
  const PhotoStats({
    required this.sharpness,
    required this.brightness,
    required this.contrast,
    required this.highlightClip,
    required this.shadowClip,
    this.colorLayout = const [],
  });

  /// 라플라시안 분산 (0~255 스케일 기준).
  final double sharpness;

  /// 평균 밝기 0~1.
  final double brightness;

  /// 밝기 표준편차 0~1.
  final double contrast;

  /// 하얗게 날아간 픽셀 비율.
  final double highlightClip;

  /// 까맣게 뭉개진 픽셀 비율.
  final double shadowClip;

  /// 4×4 격자 칸별 평균 RGB(0~1, 48개). 유사샷 판별용 색 배치.
  final List<double> colorLayout;

  /// 노출 적절성 (높을수록 좋음, 콘서트 사진에 맞춰 목표 밝기를 낮게 잡음).
  double get exposure =>
      1 -
      (brightness - 0.38).abs() * 1.2 -
      highlightClip * 1.5 -
      math.max(0, shadowClip - 0.35) * 0.8 +
      math.min(contrast, 0.25);

  static PhotoStats fromRgba(Uint8List rgba, int width, int height) {
    final n = width * height;
    final gray = Float64List(n);
    double sum = 0, sumSq = 0;
    var hi = 0, lo = 0;
    for (var i = 0; i < n; i++) {
      final r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
      final y = 0.299 * r + 0.587 * g + 0.114 * b;
      gray[i] = y;
      sum += y;
      sumSq += y * y;
      if (y >= 248) hi++;
      if (y <= 8) lo++;
    }
    final mean = sum / n;
    final variance = math.max(0.0, sumSq / n - mean * mean);

    double lSum = 0, lSumSq = 0;
    var ln = 0;
    for (var yy = 1; yy < height - 1; yy++) {
      for (var xx = 1; xx < width - 1; xx++) {
        final i = yy * width + xx;
        final lap =
            4 * gray[i] -
            gray[i - 1] -
            gray[i + 1] -
            gray[i - width] -
            gray[i + width];
        lSum += lap;
        lSumSq += lap * lap;
        ln++;
      }
    }
    final lMean = ln == 0 ? 0.0 : lSum / ln;
    final sharp = ln == 0 ? 0.0 : lSumSq / ln - lMean * lMean;

    const g = 4;
    final layout = List<double>.filled(g * g * 3, 0);
    final counts = List<int>.filled(g * g, 0);
    for (var yy = 0; yy < height; yy++) {
      for (var xx = 0; xx < width; xx++) {
        final cell = (yy * g ~/ height) * g + (xx * g ~/ width);
        final i = (yy * width + xx) * 4;
        layout[cell * 3] += rgba[i];
        layout[cell * 3 + 1] += rgba[i + 1];
        layout[cell * 3 + 2] += rgba[i + 2];
        counts[cell]++;
      }
    }
    for (var c = 0; c < g * g; c++) {
      for (var k = 0; k < 3; k++) {
        layout[c * 3 + k] /= math.max(1, counts[c]) * 255;
      }
    }

    return PhotoStats(
      sharpness: sharp,
      brightness: mean / 255,
      contrast: math.sqrt(variance) / 255,
      highlightClip: hi / n,
      shadowClip: lo / n,
      colorLayout: layout,
    );
  }
}

/// 같은 세트 안에서의 상대 순위로 0~1 화질 점수 (선명도 60% + 노출 40%).
/// 한 장뿐이면 0.5.
List<double> scorePhotoSet(List<PhotoStats> stats) {
  if (stats.isEmpty) return const [];
  if (stats.length == 1) return const [0.5];
  List<double> percentile(List<double> v) {
    final sorted = [...v]..sort();
    return [
      for (final x in v)
        // 동점은 평균 순위.
        (sorted.indexOf(x) + sorted.lastIndexOf(x)) / 2 / (v.length - 1),
    ];
  }

  final sharp = percentile([for (final s in stats) s.sharpness]);
  final expo = percentile([for (final s in stats) s.exposure]);
  return [
    for (var i = 0; i < stats.length; i++) 0.6 * sharp[i] + 0.4 * expo[i],
  ];
}

/// 색 배치 거리 (칸별 평균 RGB 차이의 평균, 0~1).
double colorLayoutDistance(PhotoStats a, PhotoStats b) {
  final n = math.min(a.colorLayout.length, b.colorLayout.length);
  if (n == 0) return 1;
  double d = 0;
  for (var i = 0; i < n; i++) {
    d += (a.colorLayout[i] - b.colorLayout[i]).abs();
  }
  return d / n;
}

class ShotInfo {
  const ShotInfo({required this.takenAt, required this.stats});

  /// EXIF DateTimeOriginal. 없으면 묶지 않음.
  final DateTime? takenAt;
  final PhotoStats stats;
}

/// 연사 / 유사샷 묶기. 촬영 시각이 [maxGap] 이내, 색 배치 거리가 [maxColorDistance]
/// 이하면 같은 그룹. 반환값은 입력 순서대로 그룹 번호, 혼자면 null.
List<int?> groupSimilarShots(
  List<ShotInfo> shots, {
  Duration maxGap = const Duration(seconds: 15),
  double maxColorDistance = 0.1,
}) {
  final order = [
    for (var i = 0; i < shots.length; i++)
      if (shots[i].takenAt != null) i,
  ]..sort((a, b) => shots[a].takenAt!.compareTo(shots[b].takenAt!));
  final group = List<int?>.filled(shots.length, null);
  var next = 0;
  for (var k = 1; k < order.length; k++) {
    final prev = shots[order[k - 1]], cur = shots[order[k]];
    final gap = cur.takenAt!.difference(prev.takenAt!);
    if (gap <= maxGap &&
        colorLayoutDistance(prev.stats, cur.stats) <= maxColorDistance) {
      final g = group[order[k - 1]] ??= next++;
      group[order[k]] = g;
    }
  }
  return group;
}
