import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/page_layout.dart';
import 'scrapbook_page_background.dart';

class _TextBox {
  final String id;
  final Offset anchor;
  final TextEditingController controller;
  final FocusNode focus = FocusNode();
  Offset offset;
  double scale;
  double rotation;

  /// page_layout에서 불러온 중심(px)/폭(px). 글자 크기로 상자를 잰 첫 배치 때
  /// offset/scale로 바꾸고 비움.
  Offset? pendingCenter;
  double? pendingWidth;
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
  final VoidCallback? onBlankLongPress;

  /// page_layout의 자유메모(text) 아이템. null이면 아직 배치가 없는 페이지라
  /// 예전 기기 저장분 → 서버 후기 순으로 채움.
  final List<PageLayoutItem>? initialItems;

  /// 자유메모가 바뀔 때마다 정규화 좌표 아이템으로 알림 (page_layout에 합쳐 저장).
  /// null이면 예전처럼 기기에만 저장.
  final ValueChanged<List<PageLayoutItem>>? onTextsChanged;

  /// 처음 불러온(예전 기기 저장분 / 서버 후기로 만든) 메모를 알림. 저장은 하지 않음.
  final ValueChanged<List<PageLayoutItem>>? onTextsLoaded;
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
    this.onBlankLongPress,
    this.initialItems,
    this.onTextsChanged,
    this.onTextsLoaded,
  });
  @override
  State<ConcertAfterTextCanvas> createState() => ConcertAfterTextCanvasState();
}

/// 빈 메모에 보이는 안내 문구. 상자 폭도 이 문구 기준으로 잼.
const String _kEmptyHint = '더블탭하여 입력';

class ConcertAfterTextCanvasState extends State<ConcertAfterTextCanvas> {
  static const double _boxPadding = 4;
  static const double _textLayoutSlack = 8;
  static const double _minBoxWidth = 24;
  static const double _minBoxHeight = 24;
  final List<_TextBox> _boxes = [];
  final GlobalKey _sheet = GlobalKey();
  final Map<String, Rect> _rects = {};
  SharedPreferences? _prefs;
  Timer? _saveTimer;
  double _startScale = 1;
  double _startRotation = 0;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  String? _selected;
  String? _editing;

  bool get hasActiveText => _selected != null || _editing != null;
  bool _selectedTextOverDeleteZone = false;
  OverlayEntry? _deleteOverlayEntry;

  bool _isBlank(_TextBox box) => box.controller.text.trim().isEmpty;

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

  Offset _doubleTap = Offset.zero;
  bool _ready = false;
  Future<void> _writes = Future.value();
  String get _key => 'after_text_boxes_v1_${widget.storageKey}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ConcertAfterTextCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editMode != widget.editMode && !widget.editMode) {
      _deselect();
    } else if (oldWidget.editMode != widget.editMode) {
      _syncDeleteOverlay();
    }
  }

  Future<void> _load() async {
    final items = widget.initialItems;
    if (items != null) {
      // initState 안에서 동기로 채우므로 setState 없이 바로 준비 완료.
      final w = widget.width;
      for (final item in items) {
        if (item.type != PageLayoutItemType.text) continue;
        _add(
          _TextBox(
              item.ref ?? item.id,
              Offset(item.cx.clamp(0, 1).toDouble(), item.cy * w),
              item.text ?? '',
            )
            ..rotation = item.rot
            ..pendingCenter = Offset(item.cx * w, item.cy * w)
            ..pendingWidth = item.w * w,
        );
      }
      // 배치는 있는데 메모가 없으면(메모 저장 이전 배치) 서버 후기로 채움.
      if (_boxes.isEmpty && widget.initialReview.trim().isNotEmpty) {
        _add(_reviewBox());
        _notifyLoaded();
      }
      _ready = true;
      return;
    }
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
      _add(_reviewBox());
    }
    setState(() => _ready = true);
    if (_boxes.isNotEmpty) _notifyLoaded();
  }

  _TextBox _reviewBox() =>
      _TextBox('original_review', const Offset(.06, 260), widget.initialReview);

  /// 첫 배치(상자 크기 측정) 뒤에 알림.
  void _notifyLoaded() {
    final onTextsLoaded = widget.onTextsLoaded;
    if (onTextsLoaded == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) onTextsLoaded(_toItems());
    });
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
      if (!box.focus.hasFocus && _editing == box.id) {
        if (_isBlank(box)) {
          _deleteTextBox(box);
          return;
        }
        setState(() => _editing = null);
        _saveLocal();
        final review = _boxes.map((b) => b.controller.text).join('\n\n');
        _writes = _writes.then((_) => widget.onReviewChanged(review));
        _syncDeleteOverlay();
      }
    });
  }

  void _saveLocal() {
    final onTextsChanged = widget.onTextsChanged;
    if (onTextsChanged != null) {
      onTextsChanged(_toItems());
      return;
    }
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
    setState(() {
      _selected = box.id;
      _editing = box.id;
      _selectedTextOverDeleteZone = false;
    });
    _syncDeleteOverlay();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing == box.id) box.focus.requestFocus();
    });
  }

  void _select(_TextBox box) {
    if (!widget.editMode) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selected = box.id;
      _editing = null;
      _selectedTextOverDeleteZone = false;
    });
    _syncDeleteOverlay();
  }

  void _deleteTextBox(_TextBox box) {
    final index = _boxes.indexOf(box);
    if (index < 0) return;
    setState(() {
      _boxes.removeAt(index);
      if (_selected == box.id) _selected = null;
      if (_editing == box.id) _editing = null;
      _selectedTextOverDeleteZone = false;
    });
    _saveLocal();
    final review = _boxes.map((b) => b.controller.text).join('\n\n');
    _writes = _writes.then((_) => widget.onReviewChanged(review));
    _syncDeleteOverlay();
    WidgetsBinding.instance.addPostFrameCallback((_) => box.dispose());
  }

  /// 화면에 그려진 상자 기준 중심/폭을 캔버스 폭 = 1 정규화 좌표로.
  List<PageLayoutItem> _toItems() {
    final w = widget.width;
    if (w <= 0) return const [];
    final items = <PageLayoutItem>[];
    for (final box in _boxes) {
      if (_isBlank(box)) continue;
      final rect = _rects[box.id];
      final center =
          box.pendingCenter ??
          (rect?.center ?? Offset(box.anchor.dx * w, box.anchor.dy)) +
              box.offset;
      final width = box.pendingWidth ?? (rect?.width ?? w * .4) * box.scale;
      final text = box.controller.text;
      final id = 'text_${box.id}';
      items.add(
        PageLayoutItem(
          id: id.length > 64 ? id.substring(0, 64) : id,
          type: PageLayoutItemType.text,
          ref: box.id,
          // 서버 검증 한도(2000자)
          text: text.length > 2000 ? text.substring(0, 2000) : text,
          cx: (center.dx / w).clamp(-0.5, 1.5).toDouble(),
          cy: (center.dy / w).clamp(-0.5, 5.0).toDouble(),
          w: (width / w).clamp(0.01, 1.5).toDouble(),
          rot: math.atan2(math.sin(box.rotation), math.cos(box.rotation)),
        ),
      );
    }
    return items;
  }

  /// 내용이 있는 자유메모가 하나라도 있는지 (자동 배치 전 초기화 확인용).
  bool get hasTexts => _boxes.any((b) => !_isBlank(b));

  /// 자유메모를 전부 지움 (합쳐 저장하던 후기도 빈 값이 됨).
  void clearAll() {
    if (_boxes.isEmpty) return;
    final removed = [..._boxes];
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _boxes.clear();
      _selected = null;
      _editing = null;
      _selectedTextOverDeleteZone = false;
    });
    _saveLocal();
    _writes = _writes.then((_) => widget.onReviewChanged(''));
    _syncDeleteOverlay();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final box in removed) {
        box.dispose();
      }
    });
  }

  void _deselect() {
    if (_selected == null && _editing == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _selected = null;
      _editing = null;
      _selectedTextOverDeleteZone = false;
    });
    _syncDeleteOverlay();
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
    // 타이핑 후 저장 대기(0.25초) 중일 때만 마지막으로 저장.
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      _saveLocal();
    }
    _removeDeleteOverlay();
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
    final text = box.controller.text.isEmpty
        ? _kEmptyHint
        : box.controller.text;
    final textScaler = MediaQuery.textScalerOf(context);
    final naturalWidth = _longestLineWidth(text, style, textScaler);
    final desiredWidth = (naturalWidth + _boxPadding * 2 + _textLayoutSlack)
        .clamp(_minBoxWidth, maxWidth);
    final preferredX = (box.anchor.dx * pageWidth).clamp(
      margin,
      pageWidth - desiredWidth - margin,
    );
    final minY = math.max(76.0, widget.minContentTop + margin);
    final y = math.max(minY, box.anchor.dy).clamp(minY, pageHeight - 48);
    final textHeight = _WrappedTextPainter.measureHeight(
      text: text,
      style: style,
      obstacles: const <Rect>[],
      textScaler: textScaler,
      width: desiredWidth - _boxPadding * 2 - _textLayoutSlack,
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

  Rect _screenDeleteZoneRect() {
    final media = MediaQuery.of(context);
    const height = 56.0;
    return Rect.fromLTWH(
      18,
      media.size.height - media.padding.bottom - height - 8,
      media.size.width - 36,
      height,
    );
  }

  void _deleteSelectedTextBox() {
    final id = _selected;
    if (id == null) return;
    for (final box in _boxes) {
      if (box.id == id) {
        _deleteTextBox(box);
        return;
      }
    }
  }

  void _syncDeleteOverlay() {
    if (!widget.editMode || _selected == null || _editing != null) {
      _removeDeleteOverlay();
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    if (_deleteOverlayEntry == null) {
      _deleteOverlayEntry = OverlayEntry(
        builder: (context) => _TextDeleteDropZone(
          rect: _screenDeleteZoneRect(),
          active: _selectedTextOverDeleteZone,
        ),
      );
      overlay.insert(_deleteOverlayEntry!);
    } else {
      _deleteOverlayEntry!.markNeedsBuild();
    }
  }

  void _removeDeleteOverlay() {
    _deleteOverlayEntry?.remove();
    _deleteOverlayEntry = null;
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
      final center = box.pendingCenter;
      if (center != null) {
        box.offset = center - rect.center;
        box.scale = ((box.pendingWidth ?? rect.width) / rect.width)
            .clamp(.6, 2.4)
            .toDouble();
        box.pendingCenter = null;
        box.pendingWidth = null;
      }
    }
    return ClipRect(
      child: SizedBox(
        key: _sheet,
        width: widget.width,
        height: widget.minHeight,
        child: Listener(
          onPointerDown: (event) {
            final activeId = _selected ?? _editing;
            if (activeId == null) return;
            final render =
                _sheet.currentContext!.findRenderObject() as RenderBox;
            final point = render.globalToLocal(event.position);
            _TextBox? activeBox;
            for (final box in _boxes) {
              if (box.id == activeId) {
                activeBox = box;
                break;
              }
            }
            final activeRect = _rects[activeId];
            if (activeBox == null ||
                activeRect == null ||
                !_transformedBounds(activeRect, activeBox).contains(point)) {
              _deselect();
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('after_blank_space'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _deselect,
                  onDoubleTapDown: widget.editMode
                      ? (d) => _doubleTap = d.localPosition
                      : null,
                  onDoubleTap: _create,
                  onLongPress: widget.editMode ? widget.onBlankLongPress : null,
                  child: const ScrapbookPageBackground(),
                ),
              ),
              ...widget.backgroundOverlays,
              ...widget.memos,
              for (final box in _boxes)
                Positioned.fromRect(
                  key: ValueKey('after_text_${box.id}'),
                  rect: _rects[box.id]!,
                  child: Transform.translate(
                    offset: box.offset,
                    child: Transform.rotate(
                      angle: box.rotation,
                      child: Transform.scale(
                        scale: box.scale,
                        child: IgnorePointer(
                          ignoring: !widget.editMode,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onLongPress: () => _select(box),
                            onDoubleTap: () => _edit(box),
                            onScaleStart:
                                _selected == box.id && _editing != box.id
                                ? (d) {
                                    _startScale = box.scale;
                                    _startRotation = box.rotation;
                                    _startOffset = box.offset;
                                    _startFocal = d.focalPoint;
                                  }
                                : null,
                            onScaleUpdate:
                                _selected == box.id && _editing != box.id
                                ? (d) {
                                    box.scale = (_startScale * d.scale)
                                        .clamp(.6, 2.4)
                                        .toDouble();
                                    box.rotation = _startRotation + d.rotation;
                                    final rect = _rects[box.id]!;
                                    box.offset = _clampTextOffset(
                                      box,
                                      rect,
                                      _startOffset +
                                          (d.focalPoint - _startFocal),
                                    );
                                    final overDelete = _screenDeleteZoneRect()
                                        .contains(d.focalPoint);
                                    if (_selectedTextOverDeleteZone !=
                                        overDelete) {
                                      _selectedTextOverDeleteZone = overDelete;
                                      _deleteOverlayEntry?.markNeedsBuild();
                                    }
                                    setState(() {});
                                  }
                                : null,
                            onScaleEnd:
                                _selected == box.id && _editing != box.id
                                ? (_) {
                                    if (_selectedTextOverDeleteZone) {
                                      _deleteSelectedTextBox();
                                      return;
                                    }
                                    setState(
                                      () => _selectedTextOverDeleteZone = false,
                                    );
                                    _deleteOverlayEntry?.markNeedsBuild();
                                    _saveLocal();
                                  }
                                : null,
                            child: DecoratedBox(
                              decoration: widget.editMode
                                  ? BoxDecoration(
                                      border: Border.all(
                                        color: _selected == box.id
                                            ? const Color(
                                                0xFFE53935,
                                              ).withValues(alpha: .95)
                                            : Colors.black.withValues(
                                                alpha: .45,
                                              ),
                                        width: _selected == box.id ? 2 : 1,
                                      ),
                                      color: Colors.white.withValues(
                                        alpha: .12,
                                      ),
                                    )
                                  : const BoxDecoration(),
                              child: Padding(
                                padding: const EdgeInsets.all(_boxPadding),
                                child: _editing == box.id
                                    ? EditableText(
                                        key: ValueKey('after_editor_${box.id}'),
                                        controller: box.controller,
                                        focusNode: box.focus,
                                        style: style,
                                        strutStyle: StrutStyle.fromTextStyle(
                                          style,
                                          forceStrutHeight: true,
                                        ),
                                        textScaler: MediaQuery.textScalerOf(
                                          context,
                                        ),
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
                                        cursorHeight:
                                            _WrappedTextPainter.lineHeight(
                                              style,
                                              MediaQuery.textScalerOf(context),
                                            ),
                                        onTapOutside: (_) =>
                                            box.focus.unfocus(),
                                      )
                                    : _WrappedText(
                                        text: box.controller.text.isEmpty
                                            ? ''
                                            : box.controller.text,
                                        hint: _kEmptyHint,
                                        style: style,
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
        ),
      ),
    );
  }
}

class _WrappedText extends StatelessWidget {
  final String text;
  final String hint;
  final TextStyle style;

  const _WrappedText({
    required this.text,
    required this.hint,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final value = text.isEmpty ? hint : text;
    return Text(
      value,
      softWrap: true,
      overflow: TextOverflow.visible,
      textScaler: MediaQuery.textScalerOf(context),
      style: text.isEmpty
          ? style.copyWith(color: style.color?.withValues(alpha: .45))
          : style,
    );
  }
}

class _TextDeleteDropZone extends StatelessWidget {
  final Rect rect;
  final bool active;

  const _TextDeleteDropZone({required this.rect, required this.active});

  @override
  Widget build(BuildContext context) {
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: Material(
          type: MaterialType.transparency,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:
                  (active ? const Color(0xFFE53935) : const Color(0xFF3E3024))
                      .withValues(alpha: active ? .9 : .68),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withValues(alpha: active ? .9 : .5),
                width: active ? 2 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .26),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.delete_outline, color: Colors.white, size: 20),
                const SizedBox(width: 7),
                Text(
                  active ? '놓으면 삭제' : '아래로 끌어 삭제',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final Map<String, double> _wrappedTextWidthCache = <String, double>{};

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
    if (width <= 0) return Rect.fromLTWH(0, y, 0, lineHeight);
    final blocked = <(double, double)>[];
    for (final obstacle in obstacles) {
      if (obstacle.bottom <= y || obstacle.top >= y + lineHeight) continue;
      final left = obstacle.left.clamp(0.0, width).toDouble();
      final right = obstacle.right.clamp(0.0, width).toDouble();
      if (right <= left) continue;
      blocked.add((left, right));
    }
    if (blocked.isEmpty) return Rect.fromLTWH(0, y, width, lineHeight);
    blocked.sort((a, b) => a.$1.compareTo(b.$1));

    var cursor = 0.0;
    var best = const (0.0, 0.0);
    for (final block in blocked) {
      if (block.$1 <= cursor) {
        cursor = math.max(cursor, block.$2);
        continue;
      }
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
    final cacheKey =
        'text=$value|family=${style.fontFamily}|size=${style.fontSize}|height=${style.height}|scale=${textScaler.scale(1)}';
    final cached = _wrappedTextWidthCache[cacheKey];
    if (cached != null) return cached;
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    if (_wrappedTextWidthCache.length > 900) {
      _wrappedTextWidthCache.remove(_wrappedTextWidthCache.keys.first);
    }
    _wrappedTextWidthCache[cacheKey] = width;
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
