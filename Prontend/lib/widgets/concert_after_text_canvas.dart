import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scrapbook_page_background.dart';

class _TextBox {
  final String id;
  final Offset anchor;
  final TextEditingController controller;
  final FocusNode focus = FocusNode();
  Offset offset;
  double scale;
  double rotation;
  _TextBox(this.id, this.anchor, String text)
    : controller = TextEditingController(text: text),
      offset = Offset.zero,
      scale = 1,
      rotation = 0;
  Map<String, Object> toJson() => {
    'id': id,
    'x': anchor.dx,
    'y': anchor.dy,
    'text': controller.text,
    'dx': offset.dx,
    'dy': offset.dy,
    'scale': scale,
    'rotation': rotation,
  };
  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}

/// One fixed sheet. Text boxes stay inside it and never add page scrolling.
class ConcertAfterTextCanvas extends StatefulWidget {
  final String storageKey;
  final String initialReview;
  final double width, minHeight;
  final double minContentTop;
  final bool editMode;
  final List<Rect> obstacles;
  final List<Widget> backgroundOverlays;
  final List<Widget> memos;
  final Future<void> Function(String) onReviewChanged;
  const ConcertAfterTextCanvas({
    super.key,
    required this.storageKey,
    required this.initialReview,
    required this.width,
    required this.minHeight,
    this.minContentTop = 0,
    required this.editMode,
    required this.obstacles,
    this.backgroundOverlays = const [],
    required this.memos,
    required this.onReviewChanged,
  });
  @override
  State<ConcertAfterTextCanvas> createState() => ConcertAfterTextCanvasState();
}

class ConcertAfterTextCanvasState extends State<ConcertAfterTextCanvas> {
  static const double _boxPadding = 4;
  static const double _minBoxWidth = 24;
  static const double _minBoxHeight = 24;
  final List<_TextBox> _boxes = [];
  final GlobalKey _sheet = GlobalKey();
  final Map<String, Rect> _rects = {};
  SharedPreferences? _prefs;
  Timer? _saveTimer;
  bool _deleteMenuOpen = false;

  bool containsTextAt(Offset globalPosition) {
    final render = _sheet.currentContext?.findRenderObject() as RenderBox?;
    if (render == null) return false;
    final point = render.globalToLocal(globalPosition);
    for (final box in _boxes) {
      final rect = _rects[box.id];
      if (rect != null && _transformedBounds(rect, box).contains(point)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _showDelete(_TextBox box) async {
    if (!mounted || _deleteMenuOpen) return;
    _deleteMenuOpen = true;
    box.focus.unfocus();
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 220,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .18),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '텍스트 박스 삭제',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('취소'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('삭제'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _deleteMenuOpen = false;
    if (!mounted || remove != true) return;
    setState(() {
      if (_active == box.id) _active = null;
      _boxes.remove(box);
    });
    _saveLocal();
    final review = _boxes.map((b) => b.controller.text).join('\n\n');
    _writes = _writes.then((_) => widget.onReviewChanged(review));
    WidgetsBinding.instance.addPostFrameCallback((_) => box.dispose());
  }

  String? _active;
  Offset _doubleTap = Offset.zero;
  bool _ready = false;
  Future<void> _writes = Future.value();
  String get _key => 'after_text_boxes_v1_${widget.storageKey}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final raw = _prefs!.getString(_key);
    if (raw != null) {
      try {
        for (final item in jsonDecode(raw) as List) {
          final box =
              _TextBox(
                  item['id'] as String,
                  Offset(
                    (item['x'] as num).toDouble(),
                    (item['y'] as num).toDouble(),
                  ),
                  item['text'] as String,
                )
                ..offset = Offset(
                  ((item as Map)['dx'] as num?)?.toDouble() ?? 0,
                  (item['dy'] as num?)?.toDouble() ?? 0,
                )
                ..scale = ((item['scale'] as num?)?.toDouble() ?? 1).clamp(
                  .6,
                  2.4,
                )
                ..rotation = ((item['rotation'] as num?)?.toDouble() ?? 0);
          _add(box);
        }
      } catch (_) {
        for (final box in _boxes) {
          box.dispose();
        }
        _boxes.clear();
      }
    }
    if (raw == null &&
        _boxes.isEmpty &&
        widget.initialReview.trim().isNotEmpty) {
      _add(
        _TextBox(
          'original_review',
          const Offset(.06, 260),
          widget.initialReview,
        ),
      );
    }
    setState(() => _ready = true);
  }

  void _add(_TextBox box) {
    _boxes.add(box);
    box.controller.addListener(() {
      if (!mounted) return;
      setState(() {});
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(milliseconds: 250), _saveLocal);
    });
    box.focus.addListener(() {
      if (!mounted) return;
      if (!box.focus.hasFocus && _active == box.id) {
        setState(() => _active = null);
        _saveLocal();
        final review = _boxes.map((b) => b.controller.text).join('\n\n');
        _writes = _writes.then((_) => widget.onReviewChanged(review));
      }
    });
  }

  void _saveLocal() {
    if (_prefs == null) return;
    unawaited(
      _prefs!.setString(
        _key,
        jsonEncode(_boxes.map((b) => b.toJson()).toList()),
      ),
    );
  }

  void _edit(_TextBox box) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _active = box.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active == box.id) box.focus.requestFocus();
    });
  }

  void _create() {
    if (!_ready || !widget.editMode) return;
    final box = _TextBox(
      DateTime.now().microsecondsSinceEpoch.toString(),
      Offset(
        (_doubleTap.dx / widget.width).clamp(0, 1),
        math.max(widget.minContentTop + 4, _doubleTap.dy),
      ),
      '',
    );
    _add(box);
    _edit(box);
    _saveLocal();
  }

  Rect _transformedBounds(Rect rect, _TextBox box, {Offset? offset}) {
    final nextOffset = offset ?? box.offset;
    final size = Size(rect.width * box.scale, rect.height * box.scale);
    final cosA = math.cos(box.rotation).abs();
    final sinA = math.sin(box.rotation).abs();
    final aabbW = size.width * cosA + size.height * sinA;
    final aabbH = size.width * sinA + size.height * cosA;
    final center = rect.center + nextOffset;
    return Rect.fromCenter(center: center, width: aabbW, height: aabbH);
  }

  Offset _clampTextOffset(_TextBox box, Rect rect, Offset requested) {
    final bounds = _transformedBounds(rect, box, offset: requested);
    var dx = requested.dx;
    var dy = requested.dy;
    if (bounds.left < 0) dx += -bounds.left;
    if (bounds.right > widget.width) dx -= bounds.right - widget.width;
    if (bounds.top < widget.minContentTop) {
      dy += widget.minContentTop - bounds.top;
    }
    if (bounds.bottom > widget.minHeight) {
      dy -= bounds.bottom - widget.minHeight;
    }
    return Offset(dx, dy);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _saveLocal();
    for (final box in _boxes) {
      box.dispose();
    }
    super.dispose();
  }

  Rect _place(_TextBox box, TextStyle style) {
    final pageWidth = widget.width;
    final pageHeight = widget.minHeight;
    const margin = 4.0;
    final maxWidth = math.max(_minBoxWidth, pageWidth - margin * 2);
    final maxHeight = math.max(_minBoxHeight, pageHeight - margin * 2);
    final text = box.controller.text.isEmpty ? '내용 입력' : box.controller.text;
    final textScaler = MediaQuery.textScalerOf(context);
    final naturalWidth = _longestLineWidth(text, style, textScaler);
    final desiredWidth = (naturalWidth + _boxPadding * 2).clamp(
      _minBoxWidth,
      maxWidth,
    );
    final preferredX = (box.anchor.dx * pageWidth).clamp(
      margin,
      pageWidth - desiredWidth - margin,
    );
    final minY = math.max(76.0, widget.minContentTop + margin);
    final y = math.max(minY, box.anchor.dy).clamp(minY, pageHeight - 48);
    final provisional = Rect.fromLTWH(
      preferredX.toDouble(),
      y.toDouble(),
      desiredWidth.toDouble(),
      maxHeight,
    );
    final localObstacles = _active == box.id
        ? const <Rect>[]
        : _localObstacles(provisional, box);
    final textHeight = _WrappedTextPainter.measureHeight(
      text: text,
      style: style,
      obstacles: localObstacles,
      textScaler: textScaler,
      width: desiredWidth - _boxPadding * 2,
      maxHeight: maxHeight,
    );
    final rect = Rect.fromLTWH(
      preferredX.toDouble(),
      y.toDouble(),
      desiredWidth.toDouble(),
      (textHeight + _boxPadding * 2)
          .clamp(
            _minBoxHeight,
            math.max(_minBoxHeight, pageHeight - margin - y),
          )
          .toDouble(),
    );
    return rect;
  }

  double _longestLineWidth(
    String text,
    TextStyle style,
    TextScaler textScaler,
  ) {
    var width = 0.0;
    for (final line in text.split('\n')) {
      final painter = TextPainter(
        text: TextSpan(text: line.isEmpty ? ' ' : line, style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      width = math.max(width, painter.width);
      painter.dispose();
    }
    return width;
  }

  List<Rect> _localObstacles(Rect rect, _TextBox box) {
    final scale = box.scale == 0 ? 1.0 : box.scale;
    return [
      for (final obstacle in widget.obstacles)
        Rect.fromLTRB(
          (obstacle.left - rect.left - box.offset.dx) / scale,
          (obstacle.top - rect.top - box.offset.dy) / scale,
          (obstacle.right - rect.left - box.offset.dx) / scale,
          (obstacle.bottom - rect.top - box.offset.dy) / scale,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontFamily: 'NanumGalmaesgeul',
      fontSize: 16,
      height: 1.45,
      color: Colors.black,
    );
    _rects.clear();
    for (final box in _boxes) {
      final rect = _place(box, style);
      _rects[box.id] = rect;
    }
    return ClipRect(
      child: SizedBox(
        key: _sheet,
        width: widget.width,
        height: widget.minHeight,
        child: Listener(
          onPointerDown: (event) {
            if (_active == null) return;
            final render =
                _sheet.currentContext!.findRenderObject() as RenderBox;
            final point = render.globalToLocal(event.position);
            if (!(_rects[_active]?.contains(point) ?? false)) {
              FocusManager.instance.primaryFocus?.unfocus();
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('after_blank_space'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                  onDoubleTapDown: widget.editMode
                      ? (d) => _doubleTap = d.localPosition
                      : null,
                  onDoubleTap: _create,
                  child: const ScrapbookPageBackground(),
                ),
              ),
              ...widget.backgroundOverlays,
              for (final box in _boxes)
                Positioned.fromRect(
                  key: ValueKey('after_text_${box.id}'),
                  rect: _rects[box.id]!,
                  child: _DraggableTextBox(
                    box: box,
                    editMode: widget.editMode,
                    isEditingText: _active == box.id,
                    style: style,
                    obstacles: _localObstacles(_rects[box.id]!, box),
                    clampOffset: (requested) =>
                        _clampTextOffset(box, _rects[box.id]!, requested),
                    onDoubleTapEdit: () => _edit(box),
                    onLongPressDelete: () => _showDelete(box),
                    onGestureEnd: _saveLocal,
                  ),
                ),
              ...widget.memos,
            ],
          ),
        ),
      ),
    );
  }
}

/// 자유메모 텍스트 박스 하나의 이동·회전·확대 제스처와 삭제용 롱프레스를
/// 전담합니다.
///
// [백엔드 수정] ConcertAfterTextCanvasState에서 분리 - 예전엔 텍스트 박스
// 하나를 끌 때도 setState가 부모 전체에 걸려서, 존재하는 모든 자유메모에
// 대해 장애물 회피 줄바꿈 계산(_place)이 매 프레임 다시 돌았습니다(포스터/
// 사진 메모 드래그 렉과 같은 원인, [_DraggableMemo] 참고). box.anchor는
// 드래그로 변하지 않아 이 박스의 rect 배치 자체는 드래그 중 안 바뀌므로,
// 부모를 다시 부를 필요 없이 이 박스의 Transform만 로컬로 갱신합니다.
class _DraggableTextBox extends StatefulWidget {
  final _TextBox box;
  final bool editMode;
  final bool isEditingText;
  final TextStyle style;
  final List<Rect> obstacles;
  final Offset Function(Offset requested) clampOffset;
  final VoidCallback onDoubleTapEdit;
  final VoidCallback onLongPressDelete;
  final VoidCallback onGestureEnd;

  const _DraggableTextBox({
    required this.box,
    required this.editMode,
    required this.isEditingText,
    required this.style,
    required this.obstacles,
    required this.clampOffset,
    required this.onDoubleTapEdit,
    required this.onLongPressDelete,
    required this.onGestureEnd,
  });

  @override
  State<_DraggableTextBox> createState() => _DraggableTextBoxState();
}

class _DraggableTextBoxState extends State<_DraggableTextBox> {
  Timer? _deleteTimer;
  Offset? _pressOrigin;
  double _startScale = 1;
  double _startRotation = 0;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  @override
  void dispose() {
    _deleteTimer?.cancel();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _deleteTimer?.cancel();
    _pressOrigin = event.position;
    _deleteTimer = Timer(
      const Duration(milliseconds: 500),
      widget.onLongPressDelete,
    );
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_pressOrigin != null &&
        (event.position - _pressOrigin!).distance > 18) {
      _deleteTimer?.cancel();
    }
  }

  void _handleScaleStart(ScaleStartDetails d) {
    final box = widget.box;
    _startScale = box.scale;
    _startRotation = box.rotation;
    _startOffset = box.offset;
    _startFocal = d.focalPoint;
  }

  void _handleScaleUpdate(ScaleUpdateDetails d) {
    final box = widget.box;
    setState(() {
      box.scale = (_startScale * d.scale).clamp(.6, 2.4).toDouble();
      box.rotation = _startRotation + d.rotation;
      box.offset = widget.clampOffset(
        _startOffset + (d.focalPoint - _startFocal),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.box;
    final style = widget.style;
    return Transform.translate(
      offset: box.offset,
      child: Transform.rotate(
        angle: box.rotation,
        child: Transform.scale(
          scale: box.scale,
          child: IgnorePointer(
            ignoring: !widget.editMode,
            child: Listener(
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: (_) => _deleteTimer?.cancel(),
              onPointerCancel: (_) => _deleteTimer?.cancel(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: widget.onDoubleTapEdit,
                onScaleStart: widget.isEditingText ? null : _handleScaleStart,
                onScaleUpdate: widget.isEditingText
                    ? null
                    : _handleScaleUpdate,
                onScaleEnd: widget.isEditingText
                    ? null
                    : (_) => widget.onGestureEnd(),
                child: RepaintBoundary(
                  child: DecoratedBox(
                    decoration: widget.editMode
                        ? BoxDecoration(
                            border: Border.all(
                              color: Colors.black.withValues(alpha: .45),
                              width: 1,
                            ),
                            color: Colors.white.withValues(alpha: .12),
                          )
                        : const BoxDecoration(),
                    child: Padding(
                      padding: const EdgeInsets.all(
                        ConcertAfterTextCanvasState._boxPadding,
                      ),
                      child: widget.isEditingText
                          ? EditableText(
                              key: ValueKey('after_editor_${box.id}'),
                              controller: box.controller,
                              focusNode: box.focus,
                              style: style,
                              strutStyle: StrutStyle.fromTextStyle(
                                style,
                                forceStrutHeight: true,
                              ),
                              textScaler: MediaQuery.textScalerOf(context),
                              cursorColor: Colors.black,
                              backgroundCursorColor: Colors.black26,
                              selectionColor: Colors.black.withValues(
                                alpha: .18,
                              ),
                              maxLines: null,
                              keyboardType: TextInputType.multiline,
                              scrollPhysics:
                                  const NeverScrollableScrollPhysics(),
                              scrollPadding: EdgeInsets.zero,
                              cursorHeight: _WrappedTextPainter.lineHeight(
                                style,
                                MediaQuery.textScalerOf(context),
                              ),
                              onTapOutside: (_) => box.focus.unfocus(),
                            )
                          : _WrappedText(
                              text: box.controller.text.isEmpty
                                  ? ''
                                  : box.controller.text,
                              hint: '더블탭하여 입력',
                              style: style,
                              obstacles: widget.obstacles,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WrappedText extends StatelessWidget {
  final String text;
  final String hint;
  final TextStyle style;
  final List<Rect> obstacles;

  const _WrappedText({
    required this.text,
    required this.hint,
    required this.style,
    required this.obstacles,
  });

  @override
  Widget build(BuildContext context) {
    final value = text.isEmpty ? hint : text;
    return CustomPaint(
      painter: _WrappedTextPainter(
        text: value,
        style: text.isEmpty
            ? style.copyWith(color: style.color?.withValues(alpha: .45))
            : style,
        obstacles: obstacles,
        textScaler: MediaQuery.textScalerOf(context),
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _WrappedTextPainter extends CustomPainter {
  final String text;
  final TextStyle style;
  final List<Rect> obstacles;
  final TextScaler textScaler;

  const _WrappedTextPainter({
    required this.text,
    required this.style,
    required this.obstacles,
    required this.textScaler,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _layoutLines(
      text: text,
      style: style,
      obstacles: obstacles,
      textScaler: textScaler,
      width: size.width,
      maxHeight: size.height,
      onLine: (line, interval, y) {
        _paintLine(canvas, line, Offset(interval.left, y), interval.width);
      },
    );
  }

  static double measureHeight({
    required String text,
    required TextStyle style,
    required List<Rect> obstacles,
    required TextScaler textScaler,
    required double width,
    required double maxHeight,
  }) {
    var bottom = 0.0;
    _layoutLines(
      text: text,
      style: style,
      obstacles: obstacles,
      textScaler: textScaler,
      width: width,
      maxHeight: maxHeight,
      onLine: (line, interval, y) {
        bottom = y + lineHeight(style, textScaler);
      },
    );
    return bottom == 0 ? lineHeight(style, textScaler) : bottom;
  }

  static double lineHeight(TextStyle style, TextScaler textScaler) =>
      textScaler.scale(style.fontSize ?? 14) * (style.height ?? 1.2);

  static void _layoutLines({
    required String text,
    required TextStyle style,
    required List<Rect> obstacles,
    required TextScaler textScaler,
    required double width,
    required double maxHeight,
    required void Function(String line, Rect interval, double y) onLine,
  }) {
    final lineHeight = _WrappedTextPainter.lineHeight(style, textScaler);
    var y = 0.0;
    for (final paragraph in text.split('\n')) {
      var rest = paragraph;
      if (rest.isEmpty) {
        y += lineHeight;
        continue;
      }
      while (rest.isNotEmpty && y + lineHeight <= maxHeight) {
        final interval = _widestIntervalForLine(
          width,
          y,
          lineHeight,
          obstacles,
        );
        if (interval.width < 12) {
          y += lineHeight;
          continue;
        }
        final split = _splitForWidth(rest, interval.width, style, textScaler);
        final line = rest.substring(0, split);
        onLine(line, interval, y);
        rest = rest.substring(split);
        y += lineHeight;
      }
    }
  }

  static Rect _widestIntervalForLine(
    double width,
    double y,
    double lineHeight,
    List<Rect> obstacles,
  ) {
    final blocked = [
      for (final obstacle in obstacles)
        if (obstacle.bottom > y && obstacle.top < y + lineHeight)
          (
            obstacle.left.clamp(0.0, width).toDouble(),
            obstacle.right.clamp(0.0, width).toDouble(),
          ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    var cursor = 0.0;
    var best = const (0.0, 0.0);
    for (final block in blocked) {
      if (block.$1 > cursor && block.$1 - cursor > best.$2 - best.$1) {
        best = (cursor, block.$1);
      }
      cursor = math.max(cursor, block.$2);
    }
    if (width - cursor > best.$2 - best.$1) best = (cursor, width);
    return Rect.fromLTRB(best.$1, y, best.$2, y + lineHeight);
  }

  static int _splitForWidth(
    String value,
    double width,
    TextStyle style,
    TextScaler textScaler,
  ) {
    var low = 1;
    var high = value.length;
    while (low < high) {
      final mid = ((low + high + 1) / 2).floor();
      if (_textWidth(value.substring(0, mid), style, textScaler) <= width) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  static double _textWidth(
    String value,
    TextStyle style,
    TextScaler textScaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  void _paintLine(Canvas canvas, String value, Offset offset, double width) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout(maxWidth: width);
    painter.paint(canvas, offset);
    painter.dispose();
  }

  @override
  bool shouldRepaint(_WrappedTextPainter oldDelegate) =>
      text != oldDelegate.text ||
      style != oldDelegate.style ||
      textScaler != oldDelegate.textScaler ||
      obstacles != oldDelegate.obstacles;
}
