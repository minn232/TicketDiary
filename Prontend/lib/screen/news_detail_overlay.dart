import 'dart:io' show Platform;
import 'dart:ui';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/news_model.dart';
import '../widgets/poster_background.dart';
import '../widgets/responsive_text.dart';

/// 소식 폴라로이드 카드를 누르면, "공연 전" 티켓과 동일한 방식으로 카드가
/// 화면 전체로 확장되며 소식 상세(포스터 + 정보 카드)를 보여주는 오버레이.
class NewsDetailOverlay extends StatefulWidget {
  /// 애니메이션 시작 위치/크기(눌린 카드의 전역 Rect)
  final Rect startRect;

  /// 축소된 상태에서 보여줄 카드 위젯(실제 카드와 동일한 UI를 넘겨주면 자연스럽게 보임)
  final Widget collapsedCard;

  final NewsModel news;

  const NewsDetailOverlay({
    super.key,
    required this.startRect,
    required this.collapsedCard,
    required this.news,
  });

  /// 다이어리/소식 화면 위에 오버레이를 띄우는 헬퍼.
  static Future<void> show(
    BuildContext context, {
    required Rect startRect,
    required Widget collapsedCard,
    required NewsModel news,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'news_detail_overlay',
      barrierColor: Colors.transparent,
      pageBuilder: (context, animation, secondaryAnimation) {
        return NewsDetailOverlay(
          startRect: startRect,
          collapsedCard: collapsedCard,
          news: news,
        );
      },
    );
  }

  @override
  State<NewsDetailOverlay> createState() => _NewsDetailOverlayState();
}

class _NewsDetailOverlayState extends State<NewsDetailOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _t;

  /// 상세 콘텐츠(포스터 위 흰 카드) 페이드 인
  late final Animation<double> _contentOpacity;

  /// 흰 카드 영역 "바깥"을 눌렀을 때만 닫히도록 판정하기 위한 key
  final GlobalKey _pageKey = GlobalKey();

  bool _isClosing = false;

  // 두 손가락 오므리기(핀치 인)로 오버레이를 닫는 기능.
  final Map<int, Offset> _pinchPointers = {};
  double? _pinchStartDistance;
  bool _pinchTriggered = false;

  // ── 포스터 확대(전체 화면) 상태 ──
  // 포스터를 크게 볼 땐 검은 패널이 카드 rect가 아니라 폰 화면 전체를
  // 덮어야 하므로, 이 레이어를 카드 안이 아니라 최상위 Stack에서 그립니다.
  bool _posterExpanded = false;
  final TransformationController _posterZoomController =
      TransformationController();
  TapDownDetails? _posterDoubleTapDetails;
  static const double _posterDoubleTapZoomScale = 2.5;

  double _pinchCurrentDistance() {
    final points = _pinchPointers.values.toList();
    return (points[0] - points[1]).distance;
  }

  void _onPinchPointerDown(PointerDownEvent event) {
    _pinchPointers[event.pointer] = event.position;
    if (_pinchPointers.length == 2) {
      _pinchStartDistance = _pinchCurrentDistance();
      _pinchTriggered = false;
    } else {
      _pinchStartDistance = null;
    }
  }

  void _onPinchPointerMove(PointerMoveEvent event) {
    if (!_pinchPointers.containsKey(event.pointer)) return;
    _pinchPointers[event.pointer] = event.position;
    final start = _pinchStartDistance;
    if (_pinchPointers.length != 2 ||
        start == null ||
        _pinchTriggered ||
        _posterExpanded) {
      return;
    }
    if (_controller.value < 0.95) return;
    if (_pinchCurrentDistance() / start < 0.7) {
      _pinchTriggered = true;
      _close();
    }
  }

  void _onPinchPointerEnd(PointerEvent event) {
    _pinchPointers.remove(event.pointer);
    if (_pinchPointers.length < 2) {
      _pinchStartDistance = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _t = CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic);
    _contentOpacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.55, 1.0, curve: Curves.easeOutCubic),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _posterZoomController.dispose();
    super.dispose();
  }

  Rect _getRectForT(Size screen, double t) {
    final end = Rect.fromCenter(
      center: screen.center(Offset.zero),
      width: screen.width * 0.90,
      height: screen.height * 0.90,
    );
    return Rect.lerp(widget.startRect, end, t)!;
  }

  double _getRadiusForT(double t) => lerpDouble(4, 18, t)!;

  void _onBackgroundTap(TapDownDetails details) => _handleOutsideTap();

  void _handleOutsideTap() {
    if (_controller.value < 0.85) return;
    _close();
  }

  Future<void> _close() async {
    if (_isClosing) return;
    _isClosing = true;
    try {
      await _controller.reverse();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  void _openPoster() => setState(() => _posterExpanded = true);

  void _collapsePoster() {
    setState(() => _posterExpanded = false);
    _posterZoomController.value = Matrix4.identity();
  }

  void _handlePosterDoubleTapDown(TapDownDetails details) =>
      _posterDoubleTapDetails = details;

  void _handlePosterDoubleTap() {
    final isZoomedIn = _posterZoomController.value.getMaxScaleOnAxis() > 1.01;
    if (isZoomedIn) {
      _posterZoomController.value = Matrix4.identity();
      return;
    }
    final position = _posterDoubleTapDetails?.localPosition ?? Offset.zero;
    const scale = _posterDoubleTapZoomScale;
    _posterZoomController.value = Matrix4.identity()
      ..translateByDouble(
        -position.dx * (scale - 1),
        -position.dy * (scale - 1),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenSize = media.size;

    return Listener(
      onPointerDown: _onPinchPointerDown,
      onPointerMove: _onPinchPointerMove,
      onPointerUp: _onPinchPointerEnd,
      onPointerCancel: _onPinchPointerEnd,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_posterExpanded) {
            _collapsePoster();
            return;
          }
          _close();
        },
        child: Material(
          type: MaterialType.transparency,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _t.value;
              final rect = _getRectForT(screenSize, t);
              final radius = _getRadiusForT(t);
              final dimOpacity = lerpDouble(0.0, 0.40, t)!;
              final expandedOpacity = Curves.easeIn.transform(
                ((t - 0.20) / 0.80).clamp(0.0, 1.0),
              );
              final collapsedOpacity = 1.0 - expandedOpacity;

              return Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        color: Colors.black.withValues(alpha: dimOpacity),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapDown: _onBackgroundTap,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Positioned.fromRect(
                    rect: rect,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Opacity(
                                opacity: collapsedOpacity,
                                child: widget.collapsedCard,
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: Opacity(
                              opacity: expandedOpacity,
                              child: _ExpandedNewsDetail(
                                pageKey: _pageKey,
                                contentOpacity: _contentOpacity,
                                news: widget.news,
                                onOutsideTap: _handleOutsideTap,
                                onPosterTap: _openPoster,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 포스터 확대 레이어 — 폰 화면 전체를 검게 덮습니다(카드
                  // rect가 아니라 최상위라 상태바 영역까지 꽉 참).
                  if (_posterExpanded) _buildFullscreenPoster(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreenPoster() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.92),
        child: Stack(
          children: [
            // 바깥(패딩·상태바) 영역 탭 → 닫기.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _collapsePoster,
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: InteractiveViewer(
                  transformationController: _posterZoomController,
                  minScale: 1.0,
                  maxScale: _posterDoubleTapZoomScale * 2,
                  // 닫기 감지기를 InteractiveViewer "안쪽"(포스터 뒤)에 둡니다.
                  // 이렇게 해야 확대 전 포스터의 실제 영역 밖(예전엔 InteractiveViewer
                  // 여백이라 눌러도 안 닫히던 자리)을 탭해도 닫힙니다. 포스터 자체는
                  // 위에 얹은 GestureDetector가 (불투명하게) 탭을 흡수해 안 닫히고,
                  // 더블탭 확대/축소만 처리합니다.
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _collapsePoster,
                        ),
                      ),
                      Center(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onDoubleTapDown: _handlePosterDoubleTapDown,
                          onDoubleTap: _handlePosterDoubleTap,
                          child: _buildLargePoster(widget.news),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLargePoster(NewsModel news) {
    final url = news.articleImageUrl;
    if (url.isEmpty) {
      return const AspectRatio(
        aspectRatio: 3 / 4,
        child: ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          child: PosterGradientPlaceholder(),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        url,
        fit: BoxFit.contain,
        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
        errorBuilder: (context, error, stackTrace) => const AspectRatio(
          aspectRatio: 3 / 4,
          child: PosterGradientPlaceholder(),
        ),
      ),
    );
  }
}

/// 확장된 소식 상세 카드(첨부 예시 스타일): 포스터 → 제목+찜 → 정보 타일 3개
/// (공연 기간/공연장/티켓팅 날짜) → 예매처 버튼(세로로 쌓기, 예매처 색상).
class _ExpandedNewsDetail extends StatelessWidget {
  final GlobalKey pageKey;
  final Animation<double> contentOpacity;
  final NewsModel news;
  final VoidCallback onOutsideTap;
  final VoidCallback onPosterTap;

  const _ExpandedNewsDetail({
    required this.pageKey,
    required this.contentOpacity,
    required this.news,
    required this.onOutsideTap,
    required this.onPosterTap,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: PosterBackground(imageUrl: news.imageUrl)),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOutsideTap,
            child: Container(color: Colors.white.withValues(alpha: 0.50)),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Center(
              child: FractionallySizedBox(
                widthFactor: 0.888 * 1.08,
                heightFactor: 0.888 * 1.08,
                child: Container(
                  key: pageKey,
                  constraints: const BoxConstraints(maxWidth: 562),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.08),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 18,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: LayoutBuilder(
                    builder: (context, cardConstraints) {
                      final k = cardConstraints.maxWidth / 350.0;
                      return FadeTransition(
                        opacity: contentOpacity,
                        child: SingleChildScrollView(
                          padding: EdgeInsets.fromLTRB(18 * k, 18 * k, 18 * k, 18 * k),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _poster(context, k),
                              SizedBox(height: 14 * k),
                              _titleRow(context, k),
                              SizedBox(height: 14 * k),
                              _infoTiles(context, k),
                              SizedBox(height: 16 * k),
                              _VendorButtons(
                                ticketingLinks: news.ticketingLinks,
                                scale: k,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _poster(BuildContext context, double k) {
    return GestureDetector(
      onTap: onPosterTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12 * k),
        child: SizedBox(
          width: double.infinity,
          height: 190 * k,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PosterBackground(imageUrl: news.articleImageUrl),
              Positioned(
                right: 10 * k,
                bottom: 10 * k,
                child: Container(
                  padding: EdgeInsets.all(6 * k),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.zoom_in, size: 18 * k, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titleRow(BuildContext context, double k) {
    return Text(
      news.concert,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: context.sp(20),
        fontWeight: FontWeight.w900,
        height: 1.2,
      ),
    );
  }

  Widget _infoTiles(BuildContext context, double k) {
    final day = news.concertDate?.day;
    // IntrinsicHeight로 Row 높이를 확정해야 stretch가 무한 높이로 터지지
    // 않고(SingleChildScrollView 안), 타일 3개가 같은 높이로 맞춰집니다.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _InfoTile(
              scale: k,
              icon: _CalendarDayIcon(day: day, scale: k),
              label: '공연 기간',
              value: news.periodText ?? '미정',
              onTap: news.concertDate != null
                  ? () => _showCalendar(
                        context,
                        title: '공연 기간',
                        start: news.concertDate!,
                        end: news.concertEndDate ?? news.concertDate!,
                        color: const Color(0xFF3DBE6B),
                      )
                  : null,
            ),
          ),
        SizedBox(width: 10 * k),
        Expanded(
          child: _InfoTile(
            scale: k,
            icon: Icon(Icons.location_on,
                size: 26 * k, color: const Color(0xFF5C4033)),
            label: '공연장',
            value: (news.venue == null || news.venue!.isEmpty) ? '미정' : news.venue!,
            onTap: (news.venue != null && news.venue!.isNotEmpty)
                ? () => _showMapPicker(context, news.venue!)
                : null,
          ),
        ),
        SizedBox(width: 10 * k),
        Expanded(
          child: _InfoTile(
            scale: k,
            icon: Icon(Icons.confirmation_num_outlined,
                size: 26 * k, color: const Color(0xFF5C4033)),
            label: '티켓팅 날짜',
            value: news.ticketingText ?? '미정',
            onTap: news.ticketingDate != null
                ? () => _showCalendar(
                      context,
                      title: '티켓팅 날짜',
                      start: news.ticketingDate!,
                      end: news.ticketingDate!,
                      color: const Color(0xFF3DBE6B),
                    )
                : null,
          ),
        ),
        ],
      ),
    );
  }
}

/// 공연 기간/티켓팅 날짜를 캘린더로 보여줍니다. [start]~[end] 구간의 날짜에
/// [color]로 색을 칠합니다(티켓팅처럼 하루면 start==end).
Future<void> _showCalendar(
  BuildContext context, {
  required String title,
  required DateTime start,
  required DateTime end,
  required Color color,
}) {
  final s = DateTime(start.year, start.month, start.day);
  final e = DateTime(end.year, end.month, end.day);
  return showDialog<void>(
    context: context,
    builder: (context) => _CalendarDialog(
      title: title,
      start: s.isAfter(e) ? e : s,
      end: e.isBefore(s) ? s : e,
      highlight: color,
    ),
  );
}

/// 달력 다이얼로그. [start]~[end]가 걸친 달(1개 또는 최대 2개)을 세로로
/// 나열해 보여주고, 해당 날짜들을 [highlight] 색의 둥근 사각형으로 칠합니다.
/// 한 주 안에서 연속된 날짜는 사이 여백 없이 하나로 이어져 칠해집니다.
class _CalendarDialog extends StatelessWidget {
  final String title;
  final DateTime start;
  final DateTime end;
  final Color highlight;

  const _CalendarDialog({
    required this.title,
    required this.start,
    required this.end,
    required this.highlight,
  });

  /// 범위가 걸친 달들(최대 2개).
  List<DateTime> get _months {
    final list = <DateTime>[];
    var m = DateTime(start.year, start.month);
    final last = DateTime(end.year, end.month);
    while (!m.isAfter(last) && list.length < 2) {
      list.add(m);
      m = DateTime(m.year, m.month + 1);
    }
    return list;
  }

  bool _on(DateTime d) => !d.isBefore(start) && !d.isAfter(end);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: context.sp(16),
                      fontWeight: FontWeight.w900,
                      color: const Color(0xFF5C4033),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: Icon(Icons.close_rounded,
                        size: context.sp(20), color: Colors.black45),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final m in _months) ...[
                        _monthView(context, m),
                        const SizedBox(height: 16),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _monthView(BuildContext context, DateTime month) {
    const weekdays = ['일', '월', '화', '수', '목', '금', '토'];
    final firstWeekday = DateTime(month.year, month.month, 1).weekday % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // 주 단위(7칸)로 나눕니다. 빈 칸은 null.
    final rows = <List<int?>>[];
    var cur = <int?>[];
    for (var i = 0; i < firstWeekday; i++) {
      cur.add(null);
    }
    for (var d = 1; d <= daysInMonth; d++) {
      cur.add(d);
      if (cur.length == 7) {
        rows.add(cur);
        cur = [];
      }
    }
    if (cur.isNotEmpty) {
      while (cur.length < 7) {
        cur.add(null);
      }
      rows.add(cur);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '${month.year}년 ${month.month}월',
            style: TextStyle(
              fontSize: context.sp(15),
              fontWeight: FontWeight.w900,
              color: const Color(0xFF3E2C22),
            ),
          ),
        ),
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: Text(
                    weekdays[i],
                    style: TextStyle(
                      fontSize: context.sp(11),
                      fontWeight: FontWeight.w700,
                      color: i == 0
                          ? const Color(0xFFE8455E)
                          : (i == 6
                              ? const Color(0xFF3D7BE8)
                              : Colors.black45),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(child: _cell(context, month, row, i)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, DateTime month, List<int?> row, int i) {
    final day = row[i];
    if (day == null) return const SizedBox(height: 36);
    final date = DateTime(month.year, month.month, day);
    final on = _on(date);
    bool nbrOn(int j) {
      if (j < 0 || j > 6) return false;
      final d = row[j];
      return d != null && _on(DateTime(month.year, month.month, d));
    }

    // 연속된 칸은 이어지도록: 좌/우 이웃도 칠해졌으면 그쪽 모서리는 각지게.
    const r = Radius.circular(11);
    final radius = on
        ? BorderRadius.horizontal(
            left: nbrOn(i - 1) ? Radius.zero : r,
            right: nbrOn(i + 1) ? Radius.zero : r,
          )
        : null;
    return Container(
      height: 36,
      alignment: Alignment.center,
      decoration: on ? BoxDecoration(color: highlight, borderRadius: radius) : null,
      child: Text(
        '$day',
        style: TextStyle(
          fontSize: context.sp(13),
          fontWeight: on ? FontWeight.w900 : FontWeight.w600,
          color: on ? Colors.white : Colors.black.withValues(alpha: 0.78),
        ),
      ),
    );
  }
}

/// 정보 타일 하나(공연 기간/공연장/티켓팅). 흰 둥근 카드에 아이콘 + 라벨 +
/// 값. [onTap]이 있으면(공연장) 누를 수 있습니다.
class _InfoTile extends StatelessWidget {
  final Widget icon;
  final String label;
  final String value;
  final double scale;
  final VoidCallback? onTap;

  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.scale,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final k = scale;
    return GestureDetector(
      onTap: onTap,
      behavior: onTap != null ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12 * k, horizontal: 4 * k),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14 * k),
          border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 28 * k, child: Center(child: icon)),
            SizedBox(height: 7 * k),
            Text(
              label,
              style: TextStyle(
                fontSize: context.sp(11),
                fontWeight: FontWeight.w700,
                color: Colors.black.withValues(alpha: 0.45),
              ),
            ),
            SizedBox(height: 4 * k),
            Text(
              value,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.sp(12),
                fontWeight: FontWeight.w800,
                color: Colors.black.withValues(alpha: 0.8),
                height: 1.25,
                decoration: onTap != null ? TextDecoration.underline : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 달력 아이콘 + 날짜 숫자(있으면). 공연 기간 타일용.
class _CalendarDayIcon extends StatelessWidget {
  final int? day;
  final double scale;

  const _CalendarDayIcon({required this.day, required this.scale});

  @override
  Widget build(BuildContext context) {
    final k = scale;
    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(Icons.calendar_today_rounded,
            size: 26 * k, color: const Color(0xFF5C4033)),
        if (day != null)
          Padding(
            padding: EdgeInsets.only(top: 4 * k),
            child: Text(
              '$day',
              style: TextStyle(
                fontSize: context.sp(9),
                fontWeight: FontWeight.w900,
                color: const Color(0xFF5C4033),
              ),
            ),
          ),
      ],
    );
  }
}

// [백엔드 수정]
// KOPIS가 실제로 준 예매처만(ticketingLinks) 버튼으로 보여주고, 눌렀을 때 진짜
// 예매 링크로 이동. Android는 android_intent_plus로 package 지정해 앱 우선
// 실행 시도(launch() 전에 canResolveActivity()로 먼저 확인), 실패하면 브라우저로
// 폴백. ticketingLinks가 비어있으면 섹션 자체를 숨김.
class _VendorButtons extends StatelessWidget {
  const _VendorButtons({required this.ticketingLinks, required this.scale});

  final Map<String, String>? ticketingLinks;
  final double scale;

  /// 예매처별 표시 이름 + 상징 색.
  static const Map<String, ({String label, Color color})> _vendors = {
    'MELON': (label: '멜론티켓', color: Color(0xFF00C639)),
    'INTERPARK': (label: '인터파크', color: Color(0xFFE51937)),
    'YES24': (label: '예스24', color: Color(0xFF0A4DA1)),
    'TICKETLINK': (label: '티켓링크', color: Color(0xFFE4002B)),
  };

  /// 각 예매처 앱의 실제 Android 패키지명(여러 개면 순서대로 시도).
  /// AndroidManifest.xml `<queries>`에도 같은 목록 필요. 인터파크는 야놀자 앱
  /// 우선 + 구버전 NOL 티켓 폴백.
  static const Map<String, List<String>> _androidPackages = {
    'INTERPARK': ['com.cultsotry.yanolja.nativeapp', 'com.interpark.app.ticket'],
    'YES24': ['com.yes24.ticket'],
    'TICKETLINK': ['kr.co.ticketlink.cne'],
    'MELON': ['com.iloen.melonticket'],
  };

  Future<void> _openVendor(String vendorKey, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    // http로 오는 링크가 많아서 https로 보정.
    final httpsUri = uri.scheme == 'http' ? uri.replace(scheme: 'https') : uri;
    final urlString = httpsUri.toString();

    if (!kIsWeb && Platform.isAndroid) {
      for (final package in _androidPackages[vendorKey] ?? const <String>[]) {
        final intent = AndroidIntent(
          action: 'action_view',
          data: urlString,
          package: package,
        );
        if (await intent.canResolveActivity() == true) {
          await intent.launch();
          return;
        }
      }
    }

    await launchUrl(httpsUri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final links = ticketingLinks;
    if (links == null || links.isEmpty) return const SizedBox.shrink();
    final k = scale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 1, color: Colors.black.withValues(alpha: 0.08)),
        SizedBox(height: 14 * k),
        SizedBox(
          width: double.infinity,
          child: Text(
            '예매처 바로가기',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(13),
              fontWeight: FontWeight.w800,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ),
        SizedBox(height: 10 * k),
        // 예매처가 여러 곳이면 바로 아래에 세로로 쌓습니다.
        for (final entry in links.entries) ...[
          _VendorButton(
            vendor: entry.key,
            info: _vendors[entry.key],
            scale: k,
            onTap: () => _openVendor(entry.key, entry.value),
          ),
          SizedBox(height: 9 * k),
        ],
      ],
    );
  }
}

/// 예매처 버튼 하나(가로 꽉 참, 예매처 상징색). 왼쪽에 예매처 이니셜 뱃지.
class _VendorButton extends StatelessWidget {
  final String vendor;
  final ({String label, Color color})? info;
  final double scale;
  final VoidCallback onTap;

  const _VendorButton({
    required this.vendor,
    required this.info,
    required this.scale,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final k = scale;
    final label = info?.label ?? vendor;
    final color = info?.color ?? const Color(0xFF5C4033);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(14 * k),
      child: InkWell(
        borderRadius: BorderRadius.circular(14 * k),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16 * k, vertical: 14 * k),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 22 * k,
                height: 22 * k,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  vendor.isNotEmpty ? vendor.substring(0, 1) : '?',
                  style: TextStyle(
                    fontSize: context.sp(12),
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
              ),
              SizedBox(width: 9 * k),
              Text(
                '$label에서 예매하기',
                style: TextStyle(
                  fontSize: context.sp(14),
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _MapProvider { kakao, naver }

/// "카카오맵/네이버지도 중 선택" 바텀시트를 띄우고, 고른 지도 앱의 검색
/// 링크를 엽니다.
Future<void> _showMapPicker(BuildContext context, String venue) async {
  final choice = await showModalBottomSheet<_MapProvider>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '지도 앱 선택',
                style: TextStyle(
                  fontSize: context.sp(15),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('카카오맵으로 보기'),
            onTap: () => Navigator.of(context).pop(_MapProvider.kakao),
          ),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('네이버지도로 보기'),
            onTap: () => Navigator.of(context).pop(_MapProvider.naver),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (choice == null) return;

  final query = Uri.encodeComponent(venue);
  final uri = switch (choice) {
    _MapProvider.kakao => Uri.parse('https://map.kakao.com/link/search/$query'),
    _MapProvider.naver => Uri.parse('https://map.naver.com/v5/search/$query'),
  };
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
