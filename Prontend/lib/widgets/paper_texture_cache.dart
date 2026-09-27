import 'dart:math' as math;
import 'dart:ui' as ui;

/// Shared, bounded raster cache. Keys describe texture settings, not widget
/// position/rotation. Background colours remain outside the cached texture.
class PaperTextureCache {
  static const int maxBytes = 24 * 1024 * 1024;
  static const double rasterScale = 2;
  static final _images = <Object, ui.Image>{};
  static int _bytes = 0;

  static void paint(
    ui.Canvas canvas,
    ui.Size size,
    Object settings,
    void Function(ui.Canvas, ui.Size) draw,
  ) {
    if (size.isEmpty || !size.width.isFinite || !size.height.isFinite) return;
    // Cap individual entries at 4 MiB, including unusually large layouts.
    final scale = math.min(
      rasterScale,
      math.sqrt(1024 * 1024 / (size.width * size.height)),
    );
    final width = math.max(1, (size.width * scale).floor());
    final height = math.max(1, (size.height * scale).floor());
    final key = (settings, size, width, height);
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
    }
    _images[key] = image;
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Offset.zero & size,
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
  }
}
