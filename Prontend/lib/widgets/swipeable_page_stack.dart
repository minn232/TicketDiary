import 'package:flutter/material.dart';
import 'dart:math' as math;

/// 여러 페이지를 겹쳐서 표시하고 스와이프로 페이지를 전환하는 위젯
/// - 오른쪽→왼쪽 스와이프: 다음 페이지
/// - 왼쪽→오른쪽 스와이프: 이전 페이지
class SwipeablePageStack extends StatefulWidget {
  final List<Widget> pages;
  final VoidCallback? onPageChanged;

  const SwipeablePageStack({
    required this.pages,
    this.onPageChanged,
    super.key,
  });

  @override
  State<SwipeablePageStack> createState() => _SwipeablePageStackState();
}

class _SwipeablePageStackState extends State<SwipeablePageStack>
    with SingleTickerProviderStateMixin {
  late int _currentPageIndex;
  late AnimationController _animationController;
  double _dragStartX = 0;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _currentPageIndex = 0;
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    _dragStartX = details.globalPosition.dx;
    _isDragging = true;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    // 드래그 중에는 애니메이션 컨트롤러를 멈춤
    if (_animationController.isAnimating) {
      _animationController.stop();
    }
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    _isDragging = false;

    final dragDistance = _dragStartX - details.globalPosition.dx;
    const swipeThreshold = 50.0;

    // 오른쪽→왼쪽 (양수 dragDistance): 다음 페이지
    if (dragDistance > swipeThreshold) {
      if (_currentPageIndex < widget.pages.length - 1) {
        setState(() => _currentPageIndex++);
        widget.onPageChanged?.call();
      }
    }
    // 왼쪽→오른쪽 (음수 dragDistance): 이전 페이지
    else if (dragDistance < -swipeThreshold) {
      if (_currentPageIndex > 0) {
        setState(() => _currentPageIndex--);
        widget.onPageChanged?.call();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          // 뒤에 보이는 페이지들 (3개까지만 표시)
          for (int i = 0; i < widget.pages.length; i++)
            if (i <= _currentPageIndex + 2)
              Positioned.fill(
                child: Transform.translate(
                  offset: Offset(0, (i - _currentPageIndex) * 8.0),
                  child: Transform.scale(
                    scale: math.max(0.92, 1.0 - (i - _currentPageIndex) * 0.04),
                    alignment: Alignment.center,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: 0.08 * (i - _currentPageIndex + 1),
                            ),
                            blurRadius: 8,
                            offset: Offset(0, 2 * (i - _currentPageIndex + 1)),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Opacity(
                          opacity: i == _currentPageIndex ? 1.0 : 0.7,
                          child: widget.pages[i],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}


