import 'package:flutter/material.dart';

/// 부모가 정한 영역 안에서만 스크롤하며 다른 항목과 위치를 공유하지 않습니다.
class SectionScrollView extends StatefulWidget {
  const SectionScrollView({super.key, required this.child});

  final Widget child;

  @override
  State<SectionScrollView> createState() => _SectionScrollViewState();
}

class _SectionScrollViewState extends State<SectionScrollView> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _SectionViewport(
      height: constraints.maxHeight,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: _controller,
          primary: false,
          child: widget.child,
        ),
      ),
    ),
  );
}

/// 아티스트처럼 다른 정보 칸 안에 있는 목록은 부모 표시 높이의 60%까지만 사용.
class LimitedSectionScrollView extends StatelessWidget {
  const LimitedSectionScrollView({
    super.key,
    required this.child,
    required this.maxHeight,
  });
  final Widget child;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final available = context
        .dependOnInheritedWidgetOfExactType<_SectionViewport>()
        ?.height;
    final height = available != null && available.isFinite
        ? (available * .6).clamp(0.0, maxHeight)
        : maxHeight;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: height),
      child: SectionScrollView(child: child),
    );
  }
}

class _SectionViewport extends InheritedWidget {
  const _SectionViewport({required this.height, required super.child});
  final double height;

  @override
  bool updateShouldNotify(_SectionViewport oldWidget) =>
      height != oldWidget.height;
}
