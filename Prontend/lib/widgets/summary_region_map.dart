import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import '../models/summary_map.dart';

const summaryInk = Color(0xFF5C4033);
const summaryPaper = Color(0xFFE5D3B9);

class SummaryRegionMap extends StatefulWidget {
  final SummaryMapData data;
  final Map<String, int>? counts;
  final String? countStatus;
  final bool partial;
  const SummaryRegionMap({
    super.key,
    required this.data,
    this.counts,
    this.countStatus,
    this.partial = false,
  });
  @override
  State<SummaryRegionMap> createState() => SummaryRegionMapState();
}

class SummaryRegionMapState extends State<SummaryRegionMap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 1,
  );
  SummaryMapRegion? _province;
  SummaryMapRegion? _selected;
  String? _pressed;
  Offset _bubbleAt = Offset.zero;
  bool _changing = false;
  bool get canGoBack => _selected != null || _province != null;

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  Future<void> _changeProvince(SummaryMapRegion? next) async {
    if (_changing) return;
    _changing = true;
    await _fade.reverse();
    if (!mounted) return;
    setState(() {
      _province = next;
      _selected = null;
      _pressed = null;
    });
    await _fade.forward();
    if (mounted) setState(() => _changing = false);
  }

  void goBack() {
    if (_changing) return;
    if (_selected != null) {
      setState(() {
        _selected = null;
        _pressed = null;
      });
    } else if (_province != null) {
      _changeProvince(null);
    }
  }

  Future<void> _activate(SummaryMapRegion region, Offset at) async {
    if (_changing) return;
    HapticFeedback.selectionClick();
    if (_province == null) {
      setState(() => _pressed = region.id);
      await _changeProvince(region);
    } else {
      setState(() {
        _selected = region;
        _pressed = region.id;
        _bubbleAt = at;
      });
    }
  }

  bool _pinched = false;

  @override
  Widget build(BuildContext context) {
    final regions = widget.data.children(_province?.id);
    return PopScope(
      canPop: !canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) goBack();
      },
      child: Column(
        children: [
          SizedBox(
            height: 29,
            child: Center(
              child: Text(
                _province?.name ?? '나의 관람 지도',
                style: const TextStyle(
                  color: summaryInk,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final layout = SummaryMapLayout(regions, size);
                final bubbleWidth = math.min(174.0, size.width - 12);
                return GestureDetector(
                  key: const ValueKey('summary-map-gestures'),
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: (_) => _pinched = false,
                  onScaleUpdate: (details) {
                    if (!_pinched &&
                        !_changing &&
                        _province != null &&
                        details.pointerCount >= 2 &&
                        details.scale < .82) {
                      _pinched = true;
                      _changeProvince(null);
                    }
                  },
                  onTapDown: (details) {
                    if (!_changing) {
                      setState(
                        () => _pressed = layout.hitTest(details.localPosition),
                      );
                    }
                  },
                  onTapCancel: () {
                    if (!_changing) setState(() => _pressed = _selected?.id);
                  },
                  onTapUp: (details) {
                    if (_changing) return;
                    final id = layout.hitTest(details.localPosition);
                    if (id == null) {
                      setState(() {
                        _selected = null;
                        _pressed = null;
                      });
                      return;
                    }
                    _activate(
                      regions.firstWhere((r) => r.id == id),
                      details.localPosition,
                    );
                  },
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: FadeTransition(
                          opacity: CurvedAnimation(
                            parent: _fade,
                            curve: Curves.easeInOut,
                          ),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(end: _pressed == null ? 0 : 1),
                            duration: const Duration(milliseconds: 150),
                            curve: Curves.easeOutCubic,
                            builder: (_, lift, _) => CustomPaint(
                              painter: _RegionPainter(
                                regions: regions,
                                layout: layout,
                                selected: _pressed,
                                lift: lift,
                                national: _province == null,
                                onSelect: (region) => _activate(
                                  region,
                                  layout.anchors[region.id]!,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_selected != null)
                        Positioned(
                          left: (_bubbleAt.dx - bubbleWidth / 2).clamp(
                            6.0,
                            math.max(6, size.width - bubbleWidth - 6),
                          ),
                          top: (_bubbleAt.dy - 86).clamp(
                            8.0,
                            math.max(8, size.height - 86),
                          ),
                          width: bubbleWidth,
                          child: IgnorePointer(
                            child: _CountBubble(
                              name: _selected!.name,
                              text: widget.counts == null
                                  ? widget.countStatus ?? '불러오는 중…'
                                  : '${widget.partial ? '확인된 ' : ''}공연 ${widget.counts![_selected!.id] ?? 0}회 관람',
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_province != null)
            const SizedBox(
              height: 19,
              child: Center(
                child: Text(
                  '두 손가락을 오므리면 전국 지도로',
                  style: TextStyle(color: summaryInk, fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CountBubble extends StatelessWidget {
  final String name;
  final String text;
  const _CountBubble({required this.name, required this.text});
  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.bottomCenter,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Transform.rotate(
          angle: math.pi / 4,
          child: const SizedBox(
            width: 13,
            height: 13,
            child: ColoredBox(color: summaryPaper),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 11),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: summaryPaper,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: summaryInk.withValues(alpha: 0.18),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                textAlign: TextAlign.center,
                style: const TextStyle(color: summaryInk, fontSize: 12),
              ),
              const SizedBox(height: 3),
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: summaryInk,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _RegionPainter extends CustomPainter {
  final List<SummaryMapRegion> regions;
  final SummaryMapLayout layout;
  final String? selected;
  final double lift;
  final bool national;
  final ValueChanged<SummaryMapRegion> onSelect;
  _RegionPainter({
    required this.regions,
    required this.layout,
    required this.selected,
    required this.lift,
    required this.national,
    required this.onSelect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // A single silhouette avoids internal drop shadows leaking across borders.
    final silhouette = Path();
    for (final path in layout.raisedFaces.values) {
      silhouette.addPath(path, Offset.zero);
    }
    canvas.drawShadow(
      silhouette.shift(const Offset(2, 4)),
      const Color(0x805C4033),
      2,
      false,
    );
    for (var z = 4; z >= 1; z--) {
      canvas.drawPath(
        silhouette.shift(Offset(z * .42, z.toDouble())),
        Paint()..color = const Color(0xFF987557),
      );
    }
    for (var i = 0; i < regions.length; i++) {
      final region = regions[i];
      final path = layout.paths[region.id];
      if (path == null) continue;
      final active = region.id == selected;
      final raised = layout.raisedFaces[region.id] ?? path;
      final surface = active
          ? path.shift(Offset(-1.5 * lift, -4 * lift))
          : path;
      if (active) {
        canvas.drawShadow(surface, summaryInk.withValues(alpha: .3), 4, false);
      }
      canvas.drawPath(
        surface,
        Paint()..color = active ? const Color(0xFFF1E2CC) : summaryPaper,
      );
      canvas.drawPath(
        active ? raised.shift(Offset(-1.5 * lift, -4 * lift)) : raised,
        Paint()
          ..color = const Color(0xFF927355)
          ..style = PaintingStyle.stroke
          ..strokeWidth = active ? 1.3 : .65
          ..strokeJoin = StrokeJoin.round,
      );
    }
    layout.labelRects.clear();
    final occupied = <Rect>[];
    for (final region in regions) {
      final anchor = layout.anchors[region.id]!;
      final shortName = national
          ? region.name
                .replaceAll('특별자치도', '')
                .replaceAll('특별자치시', '')
                .replaceAll('특별시', '')
                .replaceAll('광역시', '')
                .replaceAll('경상', '경')
                .replaceAll('충청', '충')
                .replaceAll('전라', '전')
                .replaceAll('통합', '')
          : region.name;
      final bounds = layout.paths[region.id]!.getBounds();
      final label = TextPainter(
        text: TextSpan(
          text: shortName,
          style: TextStyle(
            color: summaryInk,
            fontSize: national ? 13 : 11,
            fontFamily: 'NanumGalmaesgeul',
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 2,
      )..layout(maxWidth: math.max(28, bounds.width - 4));
      var center = Offset(
        anchor.dx.clamp(
          label.width / 2 + 2,
          math.max(label.width / 2 + 2, size.width - label.width / 2 - 2),
        ),
        anchor.dy,
      );
      var rect = Rect.fromCenter(
        center: center,
        width: math.max(30, label.width + 8),
        height: math.max(30, label.height + 6),
      );
      if (national && occupied.any((r) => r.overlaps(rect))) {
        for (final shift in [
          const Offset(-22, -15),
          const Offset(22, 15),
          const Offset(-28, 12),
          const Offset(0, -26),
          const Offset(0, 26),
        ]) {
          final candidate = rect.shift(shift);
          if (candidate.left >= 0 &&
              candidate.right <= size.width &&
              !occupied.any((r) => r.overlaps(candidate))) {
            rect = candidate;
            center += shift;
            canvas.drawLine(
              anchor,
              center,
              Paint()
                ..color = summaryInk.withValues(alpha: .45)
                ..strokeWidth = .6,
            );
            break;
          }
        }
      }
      occupied.add(rect);
      layout.labelRects[region.id] = rect;
      label.paint(canvas, center - Offset(label.width / 2, label.height / 2));
    }
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (_) => [
        for (final region in regions)
          if (layout.paths.containsKey(region.id))
            CustomPainterSemantics(
              rect: layout.paths[region.id]!.getBounds(),
              properties: SemanticsProperties(
                label: region.name,
                button: true,
                textDirection: TextDirection.ltr,
                onTap: () => onSelect(region),
              ),
            ),
      ];
  @override
  bool shouldRepaint(covariant _RegionPainter old) =>
      old.layout != layout || old.selected != selected || old.lift != lift;
  @override
  bool shouldRebuildSemantics(covariant _RegionPainter old) =>
      old.layout != layout;
}
