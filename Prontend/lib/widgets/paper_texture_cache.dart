import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Shared, bounded raster cache. Keys describe texture settings, not widget
/// position/rotation. Background colours remain outside the cached texture.
class PaperTextureCache {
  // [백엔드 수정] 24MB면 다이어리 질감만으로 거의 차서 공연을 바꿔 열 때마다 다시 그렸음 - 64MB로 늘림.
  static const int maxBytes = 64 * 1024 * 1024;
  static const double rasterScale = 2;
  static final _images = <Object, ui.Image>{};
  static int _bytes = 0;

  // [백엔드 수정] 새로 구운 횟수 - 공연후 페이지가 펼치기 전 미리 굽기가 끝났는지 볼 때 씀.
  static int bakeCount = 0;

  static void paint(
    ui.Canvas canvas,
    ui.Size size,
    Object settings,
    void Function(ui.Canvas, ui.Size) draw, {
    double opacity = 1,
  }) {
    if (size.isEmpty || !size.width.isFinite || !size.height.isFinite) return;
    if (opacity <= 0) return;
    // [백엔드 수정] 4px 단위로 맞춘 크기로 구움 - 1px 차이로 같은 질감을 또 굽던 것 방지.
    final baked = ui.Size(
      math.max(_sizeStep, (size.width / _sizeStep).round() * _sizeStep),
      math.max(_sizeStep, (size.height / _sizeStep).round() * _sizeStep),
    );
    // Cap individual entries at 4 MiB, including unusually large layouts.
    final scale = math.min(
      rasterScale,
      math.sqrt(1024 * 1024 / (baked.width * baked.height)),
    );
    final width = math.max(1, (baked.width * scale).floor());
    final height = math.max(1, (baked.height * scale).floor());
    final image = _imageFor(
      (settings, baked, width, height),
      baked,
      width,
      height,
      draw,
    );
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Offset.zero & size,
      ui.Paint()
        ..filterQuality = ui.FilterQuality.low
        ..color = ui.Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0)),
    );
  }

  static const double _sizeStep = 4;

  // [백엔드 수정] 크기와 무관한 반복 타일 - 크기가 제각각인 곳도 캐시 한 장을 같이 씀.
  static void paintTiled(
    ui.Canvas canvas,
    ui.Size size,
    Object settings, {
    required double tileSize,
    required void Function(ui.Canvas, ui.Size) draw,
    ui.Offset phase = ui.Offset.zero,
    double opacity = 1,
  }) {
    if (size.isEmpty || !size.width.isFinite || !size.height.isFinite) return;
    if (opacity <= 0) return;
    final tile = ui.Size(tileSize, tileSize);
    final pixels = math.max(1, (tileSize * rasterScale).round());
    final image = _imageFor(
      ('tile', settings, tileSize, pixels),
      tile,
      pixels,
      pixels,
      draw,
    );
    final inv = tileSize / pixels;
    final matrix = Float64List(16)
      ..[0] = inv
      ..[5] = inv
      ..[10] = 1
      ..[12] = phase.dx
      ..[13] = phase.dy
      ..[15] = 1;
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()
        ..shader = ui.ImageShader(
          image,
          ui.TileMode.repeated,
          ui.TileMode.repeated,
          matrix,
          filterQuality: ui.FilterQuality.low,
        )
        ..color = ui.Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0)),
    );
  }

  static ui.Image _imageFor(
    Object key,
    ui.Size size,
    int width,
    int height,
    void Function(ui.Canvas, ui.Size) draw,
  ) {
    var image = _images.remove(key);
    if (image == null) {
      final recorder = ui.PictureRecorder();
      final recording = ui.Canvas(recorder)
        ..scale(width / size.width, height / size.height);
      draw(recording, size);
      final picture = recorder.endRecording();
      try {
        image = picture.toImageSync(width, height);
      } finally {
        picture.dispose();
      }
      final bytes = width * height * 4;
      while (_bytes + bytes > maxBytes && _images.isNotEmpty) {
        final oldest = _images.remove(_images.keys.first)!;
        _bytes -= oldest.width * oldest.height * 4;
        oldest.dispose();
      }
      _bytes += bytes;
      bakeCount++;
    }
    _images[key] = image;
    return image;
  }
}
