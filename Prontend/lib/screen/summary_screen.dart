import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'diary_screen.dart' show buildUpcomingTicketLandscapePanel;
import '../services/summary_service.dart';
import '../widgets/diary_landscape_cover_panel.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/responsive_text.dart';

const Color _summaryPageColor = Color(0xFFCEB99B);
const Color _summaryReportColor = Color(0xFFE5D3B9);

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

/// 결산 조회 기간. 상단의 둥근 텍스트 버튼을 위로 당겨 선택합니다.
enum _SummaryPeriod {
  sixMonths('6개월', '6m'),
  oneYear('1년', '1y'),
  all('전체', 'all');

  const _SummaryPeriod(this.label, this.api);

  final String label;
  final String api;
}

class _SummaryScreenState extends State<SummaryScreen> {
  final SummaryService _service = SummaryService();

  /// 확정된(committed) 기간 + 지금 드래그로 향하고 있는 목표(target) 기간 +
  /// 그 사이 진행도(progress, 0=committed 그대로 ~ 1=target으로 완전히 이동).
  final ValueNotifier<
    ({_SummaryPeriod? committed, _SummaryPeriod? target, double progress})
  >
  _transition = ValueNotifier((committed: null, target: null, progress: 0.0));

  Future<SummaryModel>? _committedFuture;
  Future<SummaryModel>? _targetFuture;

  /// 관객 스티커 수와 기본 결산 데이터를 가져오는 전체 기간 future.
  late final Future<SummaryModel> _allFuture;

  @override
  void initState() {
    super.initState();
    _allFuture = _fetch(_SummaryPeriod.all);
  }

  @override
  void dispose() {
    _transition.dispose();
    super.dispose();
  }

  /// [_ReportDrawer]가 필요할 때(카드에 실제로 보여줄 때)만 future를
  /// FutureBuilder에 연결한다. 그 사이 실패로 끝나면 "처리되지 않은 예외"로
  /// 보고될 수 있으므로, 만들어지는 즉시 빈 리스너를 붙여둔다.
  Future<SummaryModel> _fetch(_SummaryPeriod period) {
    final future = _service.fetchSummary(period: period.api);
    unawaited(future.then((_) {}, onError: (_) {}));
    return future;
  }

  void _onPeriodTransition(
    _SummaryPeriod? committed,
    _SummaryPeriod? target,
    double progress,
  ) {
    final old = _transition.value;
    if (committed != old.committed) {
      _committedFuture = committed == null
          ? null
          : (committed == old.target ? _targetFuture : _fetch(committed));
    }
    if (target != old.target) {
      _targetFuture = target == null
          ? null
          : (target == old.committed ? _committedFuture : _fetch(target));
    }
    _transition.value = (
      committed: committed,
      target: target,
      progress: progress,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      isTabRoot: true,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.summary),
      landscapeCompanionPanel: DiaryLandscapeCoverPanel(
        child: buildUpcomingTicketLandscapePanel(),
      ),
      child: ValueListenableBuilder(
        valueListenable: _transition,
        builder: (context, t, child) {
          return ColoredBox(
            color: _summaryPageColor,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 티켓 수만큼 배치되는 랜덤 스티커 콜라주.
                ?child,
                // 하단 슬롯에서 위로 잡아당기는 결산 보고서.
                Positioned.fill(
                  child: _ReportDrawer(
                    committedFuture: _committedFuture,
                    targetFuture: _targetFuture,
                    committedPeriod: t.committed,
                    targetPeriod: t.target,
                    progress: t.progress,
                    slotColor: _summaryPageColor,
                  ),
                ),
              ],
            ),
          );
        },
        child: Positioned.fill(
          child: FutureBuilder<SummaryModel>(
            future: _allFuture,
            builder: (context, snap) {
              return _StageCollage(
                onPeriodTransition: _onPeriodTransition,
                ticketCount: snap.data?.concertCount ?? 0,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 티켓 수만큼 랜덤 스티커를 배치하고, 기간 선택 버튼을 드래그하는 결산 콜라주.
class _StageCollage extends StatefulWidget {
  final void Function(
    _SummaryPeriod? committed,
    _SummaryPeriod? target,
    double progress,
  )
  onPeriodTransition;

  /// 사용자가 등록한 전체 티켓 수. 티켓 한 장마다 스티커를 하나씩 배치합니다.
  final int ticketCount;

  const _StageCollage({
    required this.onPeriodTransition,
    required this.ticketCount,
  });

  static const String _dir = 'assets/images/summary';

  static const List<_SummaryPeriod> periodForIndex = [
    _SummaryPeriod.sixMonths,
    _SummaryPeriod.oneYear,
    _SummaryPeriod.all,
  ];

  static const List<_StickerAsset> _crowdStickerAssets = [
    _StickerAsset('sticker_01', 0.966),
    _StickerAsset('sticker_02', 0.865),
    _StickerAsset('sticker_03', 1.376),
    _StickerAsset('sticker_04', 0.953),
    _StickerAsset('sticker_05', 0.996),
    _StickerAsset('sticker_06', 1.312),
    _StickerAsset('sticker_07', 0.780),
    _StickerAsset('sticker_08', 0.913),
    _StickerAsset('sticker_09', 0.755),
    _StickerAsset('sticker_10', 0.596),
    _StickerAsset('sticker_11', 1.318),
    _StickerAsset('sticker_12', 0.853),
    _StickerAsset('sticker_13', 0.930),
    _StickerAsset('sticker_14', 0.922),
    _StickerAsset('sticker_15', 0.854),
    _StickerAsset('sticker_16', 2.455),
    _StickerAsset('sticker_17', 0.692),
    _StickerAsset('sticker_18', 1.301),
    _StickerAsset('sticker_19', 2.163),
    _StickerAsset('sticker_20', 1.000),
    _StickerAsset('sticker_21', 1.108),
    _StickerAsset('sticker_22', 1.249),
    _StickerAsset('sticker_23', 0.627),
    _StickerAsset('sticker_24', 1.009),
    _StickerAsset('sticker_25', 0.820),
    _StickerAsset('sticker_26', 1.064),
    _StickerAsset('sticker_27', 0.943),
    _StickerAsset('sticker_28', 0.534),
    _StickerAsset('sticker_29', 1.683),
    _StickerAsset('sticker_30', 0.903),
    _StickerAsset('sticker_31', 0.781),
    _StickerAsset('sticker_32', 1.067),
    _StickerAsset('sticker_33', 1.056),
    _StickerAsset('sticker_34', 0.762),
    _StickerAsset('sticker_35', 0.626),
    _StickerAsset('sticker_36', 0.939),
    _StickerAsset('sticker_37', 0.966),
    _StickerAsset('sticker_38', 1.370),
    _StickerAsset('sticker_39', 0.939),
    _StickerAsset('sticker_40', 0.495),
    _StickerAsset('sticker_41', 1.291),
    _StickerAsset('sticker_42', 2.541),
  ];

  @override
  State<_StageCollage> createState() => _StageCollageState();
}

class _StageCollageState extends State<_StageCollage>
    with SingleTickerProviderStateMixin {
  int? _draggingIndex;
  _SummaryPeriod? _committed;
  _SummaryPeriod? _target;
  late final AnimationController _progress;

  List<_Sticker> get _fans {
    final n = widget.ticketCount.clamp(0, 999);
    return [for (var i = 0; i < n; i++) _fanSticker(i)];
  }

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addListener(_report);
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _report() {
    widget.onPeriodTransition(_committed, _target, _progress.value);
  }

  void _onDragStart(int index) {
    _progress.stop();
    setState(() {
      _draggingIndex = index;
      final touched = _StageCollage.periodForIndex[index];
      _target = touched == _committed ? null : touched;
      _progress.value = 0;
    });
    _report();
  }

  void _onDrag(int index, double upDelta, double maxOffset) {
    if (_draggingIndex != index || maxOffset <= 0) return;
    final touched = _StageCollage.periodForIndex[index];
    final raising = touched == _target;
    final signedDelta = raising ? upDelta : -upDelta;
    _progress.value = (_progress.value + signedDelta / maxOffset).clamp(
      0.0,
      1.0,
    );
  }

  Future<void> _onDragEnd(int index) async {
    if (_draggingIndex != index) return;
    _draggingIndex = null;
    final target = _target;
    final commit = _progress.value >= 0.5;
    await _progress.animateTo(
      commit ? 1 : 0,
      curve: Curves.easeOutCubic,
      duration: const Duration(milliseconds: 180),
    );
    setState(() {
      if (commit) _committed = target;
      _target = null;
      _progress.value = 0;
    });
    _report();
  }

  double _offsetFor(int index, double maxOffset) {
    final period = _StageCollage.periodForIndex[index];
    if (period == _target) return _progress.value * maxOffset;
    if (period == _committed && _target != _committed) {
      return (1 - _progress.value) * maxOffset;
    }
    return 0;
  }

  /// [index]번째(0부터) 관객 스티커. 페이지 상단부터 보고서 슬롯 직전까지의
  /// 안전 영역 안에서
  /// index 기반 의사랜덤으로 위치와 크기를 정해 rebuild 때 흔들리지 않게 합니다.
  _Sticker _fanSticker(int index) {
    final random = math.Random(0x51A7C0DE ^ (index * 0x45D9F3B));
    final asset =
        _StageCollage._crowdStickerAssets[random.nextInt(
          _StageCollage._crowdStickerAssets.length,
        )];
    final rawFx = 0.08 + random.nextDouble() * 0.84;
    var rawFy = random.nextDouble();
    // 기간 선택 망치들이 있는 상단 좌/중/우 영역과 과하게 겹치지 않도록,
    // 그 부근에 걸리면 살짝 아래로 밀어 랜덤한 느낌은 유지합니다.
    final nearPeriodControls =
        rawFy < 0.38 &&
        ((rawFx > 0.02 && rawFx < 0.36) ||
            (rawFx > 0.33 && rawFx < 0.66) ||
            (rawFx > 0.64 && rawFx < 0.98));
    if (nearPeriodControls && random.nextBool()) {
      rawFy += 0.10 + random.nextDouble() * 0.06;
    }
    final widthScale = 0.72 + random.nextDouble() * 0.34;
    final aspectScale = asset.aspect > 1.7
        ? 0.82
        : (asset.aspect < 0.7 ? 0.88 : 1.0);
    return _Sticker(
      asset.name,
      rawFx.clamp(0.06, 0.94),
      rawFy.clamp(0.0, 1.0),
      (0.18 * widthScale * aspectScale).clamp(0.10, 0.25),
      asset.aspect,
    );
  }

  Widget _positioned(_Sticker s, double w, double h) {
    final wpx = s.wf * w;
    final hpx = wpx / s.aspect;
    final slotTop = h - context.rs(34) - context.rs(7);
    final minTop = 0.0;
    final maxTop = (slotTop - hpx).clamp(minTop, h).toDouble();
    final top = minTop + (maxTop - minTop) * s.fy;
    return Positioned(
      left: s.fx * w - wpx / 2,
      top: top,
      width: wpx,
      height: hpx,
      child: RepaintBoundary(
        child: Padding(
          padding: EdgeInsets.all(context.rs(3)),
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              // 투명 PNG의 알파 경계를 원형으로 확장해 둥근 흰 테두리를 만든다.
              for (var i = 0; i < 16; i++)
                Transform.translate(
                  offset: Offset(
                    math.cos(i * math.pi / 8) * context.rs(3),
                    math.sin(i * math.pi / 8) * context.rs(3),
                  ),
                  child: Image.asset(
                    '${_StageCollage._dir}/stickers/${s.name}.png',
                    fit: BoxFit.contain,
                    color: Colors.white,
                    colorBlendMode: BlendMode.srcIn,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              Image.asset(
                '${_StageCollage._dir}/stickers/${s.name}.png',
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, full) {
        final halfBar =
            (full.maxWidth * DiaryPageFrame.binderBarWidthRatio + 5) / 2;
        return Padding(
          padding: EdgeInsets.only(
            left: halfBar,
            right: halfBar,
            bottom: halfBar,
            top: halfBar,
          ),
          child: ClipRect(
            child: LayoutBuilder(
              builder: (context, c) {
                final w = c.maxWidth;
                final h = c.maxHeight;
                final maxOffset = context.rs(44);
                final pillW = 0.29 * w;
                final pillH = context.rs(51);
                return AnimatedBuilder(
                  animation: _progress,
                  builder: (context, _) {
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final s in _fans) _positioned(s, w, h),
                        for (
                          var i = 0;
                          i < _StageCollage.periodForIndex.length;
                          i++
                        )
                          _PeriodDragPill(
                            period: _StageCollage.periodForIndex[i],
                            left: _periodPillLeft(i, w, pillW),
                            top:
                                _periodPillTop(i, h, pillH) -
                                _offsetFor(i, maxOffset),
                            lift: _offsetFor(i, maxOffset),
                            width: pillW,
                            height: pillH,
                            active:
                                _StageCollage.periodForIndex[i] == _committed,
                            moving: _StageCollage.periodForIndex[i] == _target,
                            onDragStart: () => _onDragStart(i),
                            onDragDelta: (d) => _onDrag(i, d, maxOffset),
                            onDragEnd: () => _onDragEnd(i),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }
}

double _periodPillLeft(int index, double pageWidth, double pillWidth) {
  const seeds = [0.04, 0.67, 0.35];
  return (seeds[index] * pageWidth).clamp(0.0, pageWidth - pillWidth);
}

double _periodPillTop(int index, double pageHeight, double pillHeight) {
  const seeds = [0.11, 0.23, 0.35];
  final reportSafeBottom = pageHeight * 0.46;
  return (seeds[index] * pageHeight).clamp(
    0.0,
    (reportSafeBottom - pillHeight).clamp(0.0, pageHeight),
  );
}

class _PeriodDragPill extends StatelessWidget {
  final _SummaryPeriod period;
  final double left;
  final double top;
  final double lift;
  final double width;
  final double height;
  final bool active;
  final bool moving;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragDelta;
  final VoidCallback onDragEnd;

  const _PeriodDragPill({
    required this.period,
    required this.left,
    required this.top,
    required this.lift,
    required this.width,
    required this.height,
    required this.active,
    required this.moving,
    required this.onDragStart,
    required this.onDragDelta,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    const bg = _summaryReportColor;
    const fg = Color(0xFF2F251A);
    final reactionScale = moving ? 1.06 : 1.0;
    final handleWidth = width * 0.44;
    final handleHeight = height * 1.35;
    final holeWidth = handleWidth * 1.14;
    final holeHeight = holeWidth / 10;
    final holeTop = lift + height + 4;
    final holeBottom = holeTop + holeHeight;
    final totalHeight = holeBottom;
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: totalHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => onDragStart(),
        onVerticalDragUpdate: (d) => onDragDelta(-d.primaryDelta!),
        onVerticalDragEnd: (_) => onDragEnd(),
        onVerticalDragCancel: onDragEnd,
        child: AnimatedScale(
          scale: reactionScale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topCenter,
            children: [
              Positioned(
                top: holeTop,
                width: holeWidth,
                height: holeHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF4F3C28),
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 3,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 0,
                width: width,
                height: holeBottom,
                child: ClipRect(
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.topCenter,
                    children: [
                      Positioned(
                        top: height - 2,
                        width: handleWidth,
                        height: handleHeight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: bg,
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(5),
                            ),
                            border: Border.all(
                              color: const Color(
                                0xFF5C4033,
                              ).withValues(alpha: 0.35),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.07),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 0,
                width: width,
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0xFF5C4033).withValues(alpha: 0.35),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.105),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      period.label,
                      style: TextStyle(
                        fontSize: context.sp(18),
                        fontWeight: FontWeight.w900,
                        color: fg,
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

class _StickerAsset {
  final String name;
  final double aspect;

  const _StickerAsset(this.name, this.aspect);
}

/// 콜라주 스티커 하나.
class _Sticker {
  final String name;
  final double fx;
  final double fy;
  final double wf;
  final double aspect;

  const _Sticker(this.name, this.fx, this.fy, this.wf, this.aspect);
}

/// 하단 슬롯("구멍")에서 위로 잡아당겨 여는 결산 보고서.
///
/// 기본(접힘) 상태에선 제목 줄만 슬롯 위로 튀어나와 있고, 위로 드래그하면
/// 보고서 내용이 다 올라옵니다(이 펼침/접힘은 기간 전환과 무관한 별개
/// 기능). 위젯의 아래쪽 끝은 항상 슬롯 아래(구멍 속)에 남아 있습니다.
///
/// 기본 결산 기간은 전체로 고정되어 있으며, 카드 자체는 위아래로 드래그해서
/// 펼치고 접을 수 있습니다.
class _ReportDrawer extends StatefulWidget {
  final Future<SummaryModel>? committedFuture;
  final Future<SummaryModel>? targetFuture;
  final _SummaryPeriod? committedPeriod;
  final _SummaryPeriod? targetPeriod;
  final double progress;

  /// 슬롯 아래(구멍)를 덮는 색 = 페이지 배경색.
  final Color slotColor;

  const _ReportDrawer({
    required this.committedFuture,
    required this.targetFuture,
    required this.committedPeriod,
    required this.targetPeriod,
    required this.progress,
    required this.slotColor,
  });

  @override
  State<_ReportDrawer> createState() => _ReportDrawerState();
}

/// [_ReportDrawerState._displayState]의 결과: 지금 카드에 실제로 그릴
/// 기간/데이터와, 얼마나 구멍 속에 숨어야 하는지(0=완전히 보임, 1=완전히
/// 숨음).
class _CardDisplay {
  const _CardDisplay(this.period, this.future, this.hideAmt);
  final _SummaryPeriod? period;
  final Future<SummaryModel>? future;
  final double hideAmt;
}

class _ReportDrawerState extends State<_ReportDrawer>
    with SingleTickerProviderStateMixin {
  /// 0 = 접힘(제목만), 1 = 펼침(내용 다 보임). 기간 전환과는 무관하게,
  /// 카드 자체를 위아래로 드래그해서 펼치고 접는 별개 기능.
  late final AnimationController _c;

  _SummaryPeriod? _lastDisplayedPeriod;

  /// committed/target/progress로부터 "지금 카드에 뭘 그릴지"를 계산한다.
  /// - 둘 다 있으면(다른 기간으로 바로 전환): 앞 절반(progress<0.5)은
  ///   committed가 가라앉고, 뒤 절반은 target이 올라온다.
  /// - committed만 있으면(내리는 중): 전체 구간이 committed가 가라앉는 것.
  /// - target만 있으면(올리는 중): 전체 구간이 target이 올라오는 것.
  /// - 둘 다 없으면: 보여줄 게 없다(완전히 숨음).
  _CardDisplay _displayState(_ReportDrawer w) {
    final hasOld = w.committedPeriod != null;
    final hasNew = w.targetPeriod != null;
    final p = w.progress.clamp(0.0, 1.0);
    if (hasOld && hasNew) {
      if (p < 0.5) {
        return _CardDisplay(
          w.committedPeriod,
          w.committedFuture,
          (p * 2).clamp(0.0, 1.0),
        );
      }
      return _CardDisplay(
        w.targetPeriod,
        w.targetFuture,
        (2 - p * 2).clamp(0.0, 1.0),
      );
    }
    if (hasOld) {
      return _CardDisplay(w.committedPeriod, w.committedFuture, p);
    }
    if (hasNew) {
      return _CardDisplay(w.targetPeriod, w.targetFuture, 1 - p);
    }
    return const _CardDisplay(null, null, 1);
  }

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _lastDisplayedPeriod = _displayState(widget).period;
  }

  @override
  void didUpdateWidget(covariant _ReportDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 실제로 화면에 표시되는 기간이 바뀌면(예: 크로스오버 중 절반 지점에서
    // committed→target으로 내용이 바뀌는 순간) 새 보고서는 항상 접힘
    // 상태(제목만)로 다시 나타나게 한다.
    final displayed = _displayState(widget).period;
    if (displayed != _lastDisplayedPeriod) {
      _lastDisplayedPeriod = displayed;
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d, double bodyH) {
    if (widget.progress != 0) return;
    _c.value = (_c.value - d.primaryDelta! / bodyH).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails d) {
    if (widget.progress != 0) return;
    final v = d.primaryVelocity ?? 0;
    if (v < -220) {
      _c.animateTo(1);
    } else if (v > 220) {
      _c.animateTo(0);
    } else {
      _c.animateTo(_c.value >= 0.5 ? 1 : 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        final titleH = context.rs(52);
        final bodyH = context.rs(256);
        final holeLineY = h - context.rs(34);
        // 구멍은 완전히 둥근(pill) 모양이라 모서리 반지름 = 높이/2.
        final holeRadius = context.rs(7);
        final holeSide = w * 0.07;
        // 카드 가로 길이를 구멍의 둥근 모서리를 제외한 직선 구간에 맞춘다.
        final cardSide = holeSide + holeRadius;

        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final reveal = Curves.easeOutCubic.transform(_c.value);
            final display = _displayState(widget);
            // 카드 "바닥"은 평소엔 항상 구멍의 아래쪽 경계에 닿아 있고,
            // 위로 당길수록 키(cardHeight)만 자라 위쪽이 올라온다(덩어리를
            // 통째로 옮기는 게 아니라 바닥을 축으로 늘어난다).
            final cardHeight = titleH + reveal * bodyH;
            final normalBottom = holeLineY + holeRadius; // 구멍의 아래쪽 경계선.
            final normalTop = normalBottom - cardHeight;
            final hiddenTop = normalBottom;
            final cardTop =
                normalTop + (hiddenTop - normalTop) * display.hideAmt;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                // 슬롯 아래(구멍)를 페이지 배경색으로 덮어 카드 아래쪽을 감춤.
                Positioned(
                  top: holeLineY,
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: ColoredBox(color: widget.slotColor),
                  ),
                ),
                // 구멍(가로로 기다란 직사각형) 그래픽. 카드보다 먼저(뒤에)
                // 그려서, 카드와 겹치는 부분은 카드가 앞에 오고(구멍이
                // 카드를 가리지 않고) 겹치지 않는 부분(카드 양옆으로
                // 삐져나온 구멍 테두리)만 구멍이 그대로 보인다.
                Positioned(
                  top: holeLineY - holeRadius,
                  left: holeSide,
                  right: holeSide,
                  height: holeRadius * 2,
                  child: IgnorePointer(
                    child: _SlotMouth(baseColor: widget.slotColor),
                  ),
                ),
                // 결산 보고서 카드(드래그로 위/아래, 바닥은 구멍 아래쪽 경계에
                // 고정). 맨 앞(마지막)에 그려 구멍과 겹치는 부분에서 카드가
                // 이긴다. 구멍의 아래쪽 경계선(normalBottom) 아래로는 카드가
                // 어떤 상태에서도 절대 보이지 않도록 ClipRect로 잘라낸다.
                Positioned(
                  top: 0,
                  left: cardSide,
                  right: cardSide,
                  height: normalBottom,
                  child: ClipRect(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          top: cardTop,
                          left: 0,
                          right: 0,
                          height: cardHeight,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragUpdate: (d) =>
                                _onDragUpdate(d, bodyH),
                            onVerticalDragEnd: _onDragEnd,
                            onTap: () {
                              if (widget.progress != 0) return;
                              _c.animateTo(_c.value >= 0.5 ? 0 : 1);
                            },
                            child: display.period == null
                                ? const SizedBox.shrink()
                                : _card(
                                    context,
                                    titleH,
                                    bodyH,
                                    reveal,
                                    display.period!,
                                    display.future,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _card(
    BuildContext context,
    double titleH,
    double bodyH,
    double reveal,
    _SummaryPeriod period,
    Future<SummaryModel>? future,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _summaryReportColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(
          color: const Color(0xFF5C4033).withValues(alpha: 0.25),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.154),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 제목 줄(접힘 상태에서 유일하게 보이는 부분).
              SizedBox(
                height: titleH,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF5C4033).withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    Text(
                      '${period.label} 결산',
                      style: TextStyle(
                        fontSize: context.sp(16),
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF5C4033),
                      ),
                    ),
                  ],
                ),
              ),
              // 내용(펼치면 올라와 보임). 카드 바닥이 구멍 아래쪽 경계에
              // 고정된 채 늘어나는 구조라, 내용 높이도 reveal에 맞춰 함께
              // 자란다.
              SizedBox(
                height: reveal * bodyH,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, context.rs(10)),
                  child: FutureBuilder<SummaryModel>(
                    future: future,
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: Colors.brown,
                            ),
                          ),
                        );
                      }
                      if (snap.hasError) {
                        return _empty(context, '결산을 불러오지 못했어요.');
                      }
                      final data = snap.data;
                      if (data == null || data.concertCount == 0) {
                        return _empty(context, '아직 이 기간의 공연 기록이 없어요.');
                      }
                      return SingleChildScrollView(
                        child: _stats(context, data),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          // 카드 아래 경계(=구멍의 아래쪽 경계와 맞닿는 자리)에서 위로
          // 지는 그림자. 구멍 속에 꽂힌 페이지가 살짝 그늘져 보여, 카드가
          // 실제로 구멍 속까지 이어져 있는 것처럼 보이게 한다.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: context.rs(16),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // 카드의 아래쪽 모서리는 각져 있으므로(둥근 건 위쪽뿐)
                  // 그림자도 borderRadius 없이 그대로 사각으로 맞춘다.
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.2),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, String msg) {
    return Center(
      child: Text(
        msg,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: context.sp(13), color: Colors.black54),
      ),
    );
  }

  Widget _stats(BuildContext context, SummaryModel d) {
    final spending = d.totalSpending.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
    String pct(double ratio) => '${(ratio * 100).round()}%';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _row(context, '🎟️', '총 관람 횟수', '${d.concertCount}회'),
        _row(context, '💰', '총 지출 금액', '$spending원'),
        _row(context, '🎭', '가장 많이 본 장르', d.favoriteGenre),
        _row(context, '🎵', '들은 곡', '${d.songCount}곡'),
        _row(
          context,
          '🧍',
          '스탠딩 / 좌석',
          '${pct(d.standingRatio)} / ${pct(d.seatRatio)}',
        ),
        _row(
          context,
          '🎬',
          '개막일 / 막콘',
          '${pct(d.firstConcertRatio)} / ${pct(d.lastConcertRatio)}',
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String emoji, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(emoji, style: TextStyle(fontSize: context.sp(15))),
          const SizedBox(width: 9),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: context.sp(13.5),
              fontWeight: FontWeight.w700,
              color: Colors.black.withValues(alpha: 0.6),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.sp(14),
                fontWeight: FontWeight.w900,
                color: const Color(0xFF3E2C22),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 결산 보고서가 나오는 "구멍"(가로로 긴 직사각형 슬롯). 안쪽은 페이지
/// 배경색 그대로 채워(뚫린 구멍 너머로 페이지 바닥이 그대로 보이는 느낌)
/// 테두리에만 안으로 파인 듯한 그림자를 둔다.
class _SlotMouth extends StatelessWidget {
  /// 구멍 안쪽을 채우는 색(=페이지 배경색과 동일).
  final Color baseColor;

  const _SlotMouth({required this.baseColor});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Positioned.fill로 감싸지 않으면 이 DecoratedBox는 child가
            // 없어(느슨한 제약 아래) 크기가 0으로 줄어들어 아예 그려지지
            // 않는다.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: baseColor,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.105),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
            // 테두리에만 그림자(안쪽으로 파인 느낌). 원형(방사형) 그라데이션이
            // 아니라 네 변에서 각각 안쪽으로 옅어지는 네모 형태의 그림자
            // ([_BoxInnerShadow])를 쓴다. 가운데는 완전히 투명해 위에서 채운
            // 페이지 색이 그대로 보인다.
            Positioned.fill(
              child: _BoxInnerShadow(
                borderRadius: 999,
                reach: c.maxHeight * 0.45,
                alpha: 0.2,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 안쪽으로 파인 사각형(네모) 그림자. 원형/타원 그라데이션 대신, 네 변에서
/// 각각 안쪽으로 옅어지는 그라데이션 띠를 겹쳐 흉내낸다([news_screen.dart]의
/// `_InnerShadowFrame`과 같은 기법).
class _BoxInnerShadow extends StatelessWidget {
  final double borderRadius;
  final double reach;
  final double alpha;

  const _BoxInnerShadow({
    required this.borderRadius,
    required this.reach,
    required this.alpha,
  });

  @override
  Widget build(BuildContext context) {
    Widget edge({
      double? left,
      double? top,
      double? right,
      double? bottom,
      double? width,
      double? height,
      required Alignment begin,
      required Alignment end,
    }) {
      return Positioned(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: begin,
              end: end,
              colors: [
                Colors.black.withValues(alpha: alpha),
                Colors.black.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Stack(
        children: [
          edge(
            left: 0,
            top: 0,
            right: 0,
            height: reach,
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          edge(
            left: 0,
            bottom: 0,
            right: 0,
            height: reach,
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
          ),
          edge(
            left: 0,
            top: 0,
            bottom: 0,
            width: reach,
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          edge(
            right: 0,
            top: 0,
            bottom: 0,
            width: reach,
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
          ),
        ],
      ),
    );
  }
}
