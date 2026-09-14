import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'hanji_texture.dart';
import 'concert_after_palette.dart';

const double kEnvelopeBreezeAmplitude = .2;

/// 크라프트지 봉투. 덮개는 [opening]에 따라 뒤로 젖혀집니다.
class ConcertEnvelope extends StatefulWidget {
  final VoidCallback? onTap;
  final double opening;
  final bool idleFlutter;
  final bool showBodyShadow;
  final Color? color;

  const ConcertEnvelope({
    super.key,
    this.onTap,
    this.opening = 0,
    this.idleFlutter = false,
    this.showBodyShadow = true,
    this.color,
  });

  @override
  State<ConcertEnvelope> createState() => _ConcertEnvelopeState();
}

class _ConcertEnvelopeState extends State<ConcertEnvelope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breeze = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBreeze();
  }

  @override
  void didUpdateWidget(covariant ConcertEnvelope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBreeze();
  }

  void _syncBreeze() {
    final enabled =
        widget.idleFlutter &&
        widget.opening == 0 &&
        !MediaQuery.disableAnimationsOf(context);
    if (enabled) {
      if (!_breeze.isAnimating) _breeze.repeat(reverse: true);
    } else {
      _breeze.stop();
      _breeze.value = 0;
    }
  }

  @override
  void dispose() {
    _breeze.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '공연 기록 편지봉투',
    child: GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AspectRatio(
        aspectRatio: 1.55,
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _breeze,
            builder: (context, child) => CustomPaint(
              painter: _EnvelopePainter(
                widget.opening +
                    kEnvelopeBreezeAmplitude *
                        Curves.easeInOutSine.transform(_breeze.value),
                widget.showBodyShadow,
                widget.color ?? concertAfterTone(hue: 31),
                PosterMoodScope.of(context)?.textureOpacity ??
                    kHanjiTextureOpacity,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _EnvelopePainter extends CustomPainter {
  final double opening;
  final bool showBodyShadow;
  final Color color;
  final double textureOpacity;
  _EnvelopePainter(
    this.opening,
    this.showBodyShadow,
    this.color,
    this.textureOpacity,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(3),
    );
    if (showBodyShadow) {
      canvas.drawShadow(Path()..addRRect(rect), Colors.black54, 7, true);
    }
    canvas.drawRRect(rect, Paint()..color = color);
    HanjiTexturePainter(opacity: textureOpacity).paint(canvas, size);
    final front = Path()
      ..moveTo(0, 0)
      ..lineTo(w * .5, h * .6)
      ..lineTo(w, 0)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(
      front,
      Paint()
        ..shader = LinearGradient(
          colors: [color, color],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(Offset.zero & size),
    );
    canvas.save();
    canvas.clipPath(front);
    HanjiTexturePainter(opacity: textureOpacity).paint(canvas, size);
    canvas.restore();
    canvas.drawPath(
      Path()
        ..moveTo(0, h)
        ..lineTo(w * .5, h * .48)
        ..lineTo(w, h),
      Paint()
        ..color = const Color(0x33815A31)
        ..style = PaintingStyle.stroke,
    );
    final tip = h * .65 * math.cos(opening * math.pi);
    final flap = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..quadraticBezierTo(w * .62, tip * .88, w * .55, tip)
      ..quadraticBezierTo(w * .5, tip * 1.08, w * .44, tip * .96)
      ..close();
    canvas.drawShadow(flap, Colors.black45, 5 * (1 - opening), true);
    canvas.drawPath(
      flap,
      Paint()
        ..shader = LinearGradient(
          colors: opening < .5 ? [color, color] : [color, color],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(Offset.zero & size),
    );
    canvas.save();
    canvas.clipPath(flap);
    HanjiTexturePainter(opacity: textureOpacity).paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EnvelopePainter oldDelegate) =>
      textureOpacity != oldDelegate.textureOpacity ||
      opening != oldDelegate.opening ||
      showBodyShadow != oldDelegate.showBodyShadow ||
      color != oldDelegate.color;
}

/// 같은 애니메이션을 역재생해 편지를 접고 봉투로 돌려보냅니다.
Future<void> showConcertLetter({
  required BuildContext context,
  required Rect source,
  Color? envelopeColor,
  required List<Widget> columns,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '편지 접기',
  barrierColor: Colors.transparent,
  transitionDuration: const Duration(milliseconds: 1600),
  pageBuilder: (context, animation, secondaryAnimation) =>
      const SizedBox.shrink(),
  transitionBuilder: (context, animation, secondaryAnimation, child) {
    double phase(double start, double end) => Curves.easeInOutCubic.transform(
      ((animation.value - start) / (end - start)).clamp(0.0, 1.0),
    );
    final lift = phase(.15, .42);
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('letter_outside'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (animation.status == AnimationStatus.completed) {
                  Navigator.of(context).pop();
                }
              },
              child: ColoredBox(
                color: Colors.black.withValues(alpha: .22 * lift),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: source,
            child: IgnorePointer(
              child: ConcertEnvelope(
                opening: phase(0, .25),
                color: envelopeColor,
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: animation.status != AnimationStatus.completed,
              child: SafeArea(
                minimum: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 40,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: _FoldingLetter(
                      source: source,
                      lift: lift,
                      horizontal: phase(.4, .7),
                      vertical: phase(.68, 1),
                      visible: animation.value > .15,
                      child: GestureDetector(
                        key: const ValueKey('integrated_concert_letter'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () {},
                        child: SingleChildScrollView(
                          child: CustomPaint(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final column in columns)
                                  Expanded(child: column),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  },
);

/// 접히는 동안에는 내용의 스냅샷을 종이 앞면에 함께 그립니다.
/// 따라서 비동기 조회 내용이 바뀌어도 종이 높이와 접힘 위치가 함께 갱신됩니다.
class _FoldingLetter extends SingleChildRenderObjectWidget {
  final Rect source;
  final double lift, horizontal, vertical;
  final bool visible;

  _FoldingLetter({
    required this.source,
    required this.lift,
    required this.horizontal,
    required this.vertical,
    required this.visible,
    required Widget child,
  }) : super(child: RepaintBoundary(child: child));

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFoldingLetter(source, lift, horizontal, vertical, visible);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFoldingLetter renderObject,
  ) {
    renderObject
      ..source = source
      ..lift = lift
      ..horizontal = horizontal
      ..vertical = vertical
      ..visible = visible
      ..markNeedsPaint();
  }
}

class _RenderFoldingLetter extends RenderProxyBox {
  Rect source;
  double lift, horizontal, vertical;
  bool visible;
  ui.Image? _paperImage;

  void _clearImage() {
    _paperImage?.dispose();
    _paperImage = null;
  }

  @override
  void performLayout() {
    final previousSize = hasSize ? size : Size.zero;
    super.performLayout();
    if (size != previousSize) _clearImage();
  }

  @override
  void dispose() {
    _clearImage();
    super.dispose();
  }

  _RenderFoldingLetter(
    this.source,
    this.lift,
    this.horizontal,
    this.vertical,
    this.visible,
  );

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!visible || child == null || size.isEmpty) return;
    if (horizontal == 1 && vertical == 1) {
      _clearImage();
      context.canvas.drawShadow(
        Path()..addRect(offset & size),
        Colors.black38,
        8,
        false,
      );
      context.canvas.save();
      context.canvas.translate(offset.dx, offset.dy);
      _LetterPaperPainter().paint(context.canvas, size);
      context.canvas.restore();
      super.paint(context, offset);
      return;
    }
    if (_paperImage == null) {
      // 합성 레이어를 반복해서 그리지 않고 한 번 캡처해 각 면에 사용합니다.
      // 닫힐 때는 현재 스크롤 위치와 최신 내용을 다시 캡처합니다.
      context.pushOpacity(offset, 0, (context, offset) {
        super.paint(context, offset);
      });
      _paperImage = (child! as RenderRepaintBoundary).toImageSync(
        pixelRatio: 2,
      );
    }
    final origin = globalToLocal(source.center);
    final center = size.center(Offset.zero);
    final position =
        Offset.lerp(origin, center, lift)! -
        Offset(0, math.sin(lift * math.pi) * 28);
    final foldedScale = math.min(
      source.width * .9 / (size.width / 3),
      source.height * .8 / (size.height / 3),
    );
    final scale = foldedScale + (1 - foldedScale) * lift;
    final base = Matrix4.identity()
      ..translateByDouble(position.dx, position.dy, 0, 1)
      ..setEntry(3, 2, -.0007)
      ..scaleByDouble(scale, scale, 1, 1)
      ..rotateZ(-.035 * math.sin(lift * math.pi))
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    double wingProgress(double progress, int index) {
      final start = index == 2 ? 0.0 : .3;
      return Curves.easeInOutSine.transform(
        ((progress - start) / .7).clamp(0.0, 1.0),
      );
    }

    // 가운데 칸을 먼저 그리고 양쪽 날개를 덮습니다.
    for (final row in [1, 0, 2]) {
      for (final col in [1, 0, 2]) {
        final w = size.width / 3;
        final h = size.height / 3;
        final hingeX = col == 0 ? w : 2 * w;
        final hingeY = row == 0 ? h : 2 * h;
        final angleX = row == 1
            ? 0.0
            : (1 - wingProgress(horizontal, row)) *
                  math.pi *
                  (row == 0 ? 1 : -1);
        final angleY = col == 1
            ? 0.0
            : (1 - wingProgress(vertical, col)) * math.pi * (col == 0 ? -1 : 1);
        final transform = base.clone()
          ..translateByDouble(0, hingeY, 0, 1)
          ..rotateX(angleX)
          ..translateByDouble(0, -hingeY, 0, 1)
          ..translateByDouble(hingeX, 0, 0, 1)
          ..rotateY(angleY)
          ..translateByDouble(-hingeX, 0, 0, 1);
        final canvas = context.canvas;
        final panel = Rect.fromLTWH(col * w, row * h, w, h);
        canvas.save();
        canvas.translate(offset.dx, offset.dy);
        canvas.transform(transform.storage);
        final bend = math.max(math.sin(angleX).abs(), math.sin(angleY).abs());
        canvas.drawRect(panel, Paint()..color = const Color(0xFFFFF8E8));
        if (horizontal == 1 && math.cos(angleX) * math.cos(angleY) > 0) {
          final image = _paperImage!;
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(
              panel.left * image.width / size.width,
              panel.top * image.height / size.height,
              panel.width * image.width / size.width,
              panel.height * image.height / size.height,
            ),
            panel,
            Paint()..filterQuality = FilterQuality.medium,
          );
        }
        canvas.drawRect(
          panel,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: bend * .16),
                const Color(0xFF694B2B).withValues(alpha: bend * .22),
              ],
            ).createShader(panel),
        );
        // 같은 종이 좌표의 선을 잘라 그려 펼친 상태와 길이·위치를 일치시킵니다.
        _paintPaperCreases(canvas, size, visibleArea: panel);
        canvas.restore();
      }
    }
  }
}

class _LetterPaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFF8E8),
    );
    _paintPaperCreases(canvas, size);
  }

  @override
  bool shouldRepaint(_LetterPaperPainter oldDelegate) => false;
}

/// 각 접힘 자국은 전체 길이의 2/3만 표시하고 양끝을 흐리게 처리합니다.
void _paintPaperCreases(Canvas canvas, Size size, {Rect? visibleArea}) {
  if (visibleArea != null) {
    canvas.save();
    canvas.clipRect(visibleArea);
  }

  void crease(Offset start, Offset end, Offset highlight) {
    final shader = LinearGradient(
      begin: start.dx == end.dx ? Alignment.topCenter : Alignment.centerLeft,
      end: start.dx == end.dx ? Alignment.bottomCenter : Alignment.centerRight,
      colors: const [
        Color(0x00755A37),
        Color(0x30755A37),
        Color(0x30755A37),
        Color(0x00755A37),
      ],
      stops: const [0, .18, .82, 1],
    ).createShader(Rect.fromPoints(start, end).inflate(2));
    canvas.drawLine(
      start,
      end,
      Paint()
        ..shader = shader
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
    canvas.drawLine(
      start,
      end,
      Paint()
        ..shader = shader
        ..strokeWidth = .65,
    );
    canvas.drawLine(
      start + highlight,
      end + highlight,
      Paint()
        ..color = const Color(0x38FFFFFF)
        ..strokeWidth = .45,
    );
  }

  for (var i = 1; i <= 2; i++) {
    final x = size.width * i / 3;
    final y = size.height * i / 3;
    crease(
      Offset(x, size.height / 6),
      Offset(x, size.height * 5 / 6),
      const Offset(1, 0),
    );
    crease(
      Offset(size.width / 6, y),
      Offset(size.width * 5 / 6, y),
      const Offset(0, 1),
    );
  }

  if (visibleArea != null) {
    canvas.restore();
  }
}
