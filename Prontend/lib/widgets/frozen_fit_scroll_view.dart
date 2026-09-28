import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

// [백엔드 수정] 공연 전 페이지 아코디언 배율 고정용 신규.
/// 화면 높이에 맞게 축소하고, [FrozenFitSection]이 펼쳐진 동안엔 배율을 유지한 채 스크롤.
class FrozenFitScrollView extends StatefulWidget {
  final Widget child;

  const FrozenFitScrollView({super.key, required this.child});

  @override
  State<FrozenFitScrollView> createState() => _FrozenFitScrollViewState();
}

class _FrozenFitScrollViewState extends State<FrozenFitScrollView> {
  final _ExpandedSections _sections = _ExpandedSections();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: _FrozenFitPage(
            viewportHeight: constraints.maxHeight,
            sections: _sections,
            child: _ExpandedSectionScope(
              sections: _sections,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}

/// 펼쳐지는 영역(아코디언 곡 목록)을 감싸서 배율 고정.
class FrozenFitSection extends SingleChildRenderObjectWidget {
  const FrozenFitSection({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderExpandedSectionMarker(_ExpandedSectionScope.maybeOf(context));
}

/// 지금 펼쳐진 영역들(렌더 객체 단위).
class _ExpandedSections {
  final Set<RenderObject> active = {};
}

class _ExpandedSectionScope extends InheritedWidget {
  final _ExpandedSections sections;

  const _ExpandedSectionScope({required this.sections, required super.child});

  static _ExpandedSections? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ExpandedSectionScope>()?.sections;

  @override
  bool updateShouldNotify(_ExpandedSectionScope oldWidget) =>
      sections != oldWidget.sections;
}

class _RenderExpandedSectionMarker extends RenderProxyBox {
  _RenderExpandedSectionMarker(this.sections);

  final _ExpandedSections? sections;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    sections?.active.add(this);
  }

  @override
  void detach() {
    sections?.active.remove(this);
    super.detach();
  }
}

class _FrozenFitPage extends SingleChildRenderObjectWidget {
  final double viewportHeight;
  final _ExpandedSections sections;

  const _FrozenFitPage({
    required this.viewportHeight,
    required this.sections,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFrozenFitPage(viewportHeight, sections);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFrozenFitPage renderObject,
  ) {
    renderObject
      ..viewportHeight = viewportHeight
      ..sections = sections;
  }
}

class _RenderFrozenFitPage extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _RenderFrozenFitPage(this._viewportHeight, this.sections);

  _ExpandedSections sections;
  double _viewportHeight;
  set viewportHeight(double value) {
    if (value == _viewportHeight) return;
    _viewportHeight = value;
    _frozenScale = null;
    markNeedsLayout();
  }

  double? _frozenScale;
  double _scale = 1;
  double _dx = 0;

  Matrix4 get _transform =>
      Matrix4.translationValues(_dx, 0, 0)..scaleByDouble(_scale, _scale, 1, 1);

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
    final height = child.size.height;
    final fit = height <= 0 || !_viewportHeight.isFinite
        ? 1.0
        : math.min(1.0, _viewportHeight / height);
    if (sections.active.isEmpty || _frozenScale == null) _frozenScale = fit;
    _scale = _frozenScale!;
    _dx = (width - width * _scale) / 2;
    size = constraints.constrain(Size(width, height * _scale));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) => context.paintChild(child, offset),
      oldLayer: layer is TransformLayer ? layer as TransformLayer : null,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (result, position) => child.hitTest(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_transform);
  }
}
