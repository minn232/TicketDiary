import 'dart:async';

import 'package:flutter/material.dart';

import '../services/summary_service.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/responsive_text.dart';

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

/// 결산 조회 기간. 무대 위 밴드 스티커(기타=6개월/드럼=1년/보컬=전체)를
/// 당겨서 고릅니다.
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
  /// 그 사이 진행도(progress, 0=committed 그대로 ~ 1=target으로 완전히
  /// 이동). 전부 [_StageCollageState]가 밴드 스티커 드래그로부터 실시간으로
  /// 계산해서 [onPeriodTransition]으로 올려준다. ValueNotifier로 들고
  /// 있어서, 이 값이 바뀔 때 페이지 전체(setState)가 아니라 배경색+결산
  /// 보고서만 다시 그린다([_StageCollage]는 그대로 캐싱).
  final ValueNotifier<({_SummaryPeriod? committed, _SummaryPeriod? target, double progress})>
      _transition = ValueNotifier((committed: null, target: null, progress: 0.0));

  Future<SummaryModel>? _committedFuture;
  Future<SummaryModel>? _targetFuture;

  /// 관객 스티커 수를 셀 때 쓰는, 기간과 무관하게 항상 "전체"로 고정된
  /// future. 6개월/1년/전체 중 무엇을 보고 있든 관객 수는 사용자가 등록한
  /// 전체 티켓 수 기준으로 늘 같아야 하므로, 기간이 바뀌어도 이 future는
  /// 다시 만들지 않는다.
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

  /// [_StageCollage]가 밴드 스티커 드래그 상태가 바뀔 때마다(매 프레임)
  /// 호출한다. committed/target이 새로 바뀌면 그 기간의 데이터를 새로
  /// 받아오되, 이미 반대쪽(committed↔target)으로 받아둔 future가 있으면
  /// (예: 드래그가 끝나 target이 committed로 확정된 경우) 재사용해서
  /// 중복 요청을 피한다.
  void _onPeriodTransition(
      _SummaryPeriod? committed, _SummaryPeriod? target, double progress) {
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
    _transition.value = (committed: committed, target: target, progress: progress);
  }

  /// 기간별 배경색: 미선택(결산)=중립 톤, 6개월=연보라, 1년=연노랑, 전체=연파랑.
  Color _colorFor(_SummaryPeriod? period) => switch (period) {
        null => const Color(0xFFEDEAE3),
        _SummaryPeriod.sixMonths => const Color(0xFFEDE6F7),
        _SummaryPeriod.oneYear => const Color(0xFFFAF3D6),
        _SummaryPeriod.all => const Color(0xFFDFEAF8),
      };

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      isTabRoot: true,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.summary),
      child: ValueListenableBuilder(
        valueListenable: _transition,
        builder: (context, t, child) {
          final bgColor =
              Color.lerp(_colorFor(t.committed), _colorFor(t.target), t.progress)!;
          return ColoredBox(
            color: bgColor,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 무대 콜라주(밴드 스티커 드래그가 여기서 일어남). progress가
                // 바뀔 때마다 이 트리 전체를 다시 만들 필요는 없으므로(무대
                // 위젯 스스로 애니메이션을 처리) child로 캐싱해 재사용한다.
                if (child != null) child,
                // 하단 슬롯에서 위로 잡아당기는 결산 보고서. 밴드 스티커
                // 중 아무것도 최대로 안 당겨져 기간이 미선택 상태여도 구멍
                // 자체는 항상 존재하고, 카드만 없다.
                Positioned.fill(
                  child: _ReportDrawer(
                    committedFuture: _committedFuture,
                    targetFuture: _targetFuture,
                    committedPeriod: t.committed,
                    targetPeriod: t.target,
                    progress: t.progress,
                    slotColor: bgColor,
                  ),
                ),
                // 페이지 안쪽에 그리는 하얀 테두리.
                const Positioned.fill(child: _WhiteInsetBorder()),
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

/// 페이지 가장자리 안쪽에 그리는 하얀 테두리(장식, 터치 통과).
class _WhiteInsetBorder extends StatelessWidget {
  const _WhiteInsetBorder();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white, width: 3),
          ),
        ),
      ),
    );
  }
}

/// 무대 공연 장면(스티커 콜라주). 밴드(기타·드럼·보컬)는 무대 플랫폼 위에
/// 발을 맞춰 세우고, 각자를 위로 당기면 그에 해당하는 기간이 선택됩니다.
/// 관객은 하단 결산 보고서와 겹치지 않도록 위쪽으로 배치합니다.
class _StageCollage extends StatefulWidget {
  final void Function(
          _SummaryPeriod? committed, _SummaryPeriod? target, double progress)
      onPeriodTransition;

  /// 사용자가 등록한 전체 티켓(관람) 수(기간 필터와 무관하게 항상 "전체"
  /// 기준). 티켓 한 장마다 관객 스티커를 하나씩 무대 앞에 세운다.
  final int ticketCount;

  const _StageCollage({
    required this.onPeriodTransition,
    required this.ticketCount,
  });

  static const String _dir = 'assets/images/summary';

  static const double _feetFrac = 0.73;

  static const _Sticker _stage = _Sticker('stage', 0.50, 0.30, 1.00, 0.881);

  // 3버튼과 겹치지 않도록 밴드를 이전보다 작게. faceFx는 각 이미지에서
  // 얼굴이 실제로 있는 가로 위치(원본 그림을 보고 눈대중으로 잰 값) —
  // 기타/보컬은 몸이 오른쪽으로 뻗어 있어 얼굴이 중앙보다 왼쪽에 있고,
  // 드럼은 좌우 대칭이라 거의 중앙이다.
  static const List<_Sticker> _band = [
    _Sticker('guitar', 0.20, 0, 0.26, 0.688, band: true, faceFx: 0.38),
    _Sticker('drum', 0.74, 0, 0.36, 1.154, band: true, faceFx: 0.52),
    _Sticker('vocal', 0.50, 0, 0.30, 0.669, band: true, faceFx: 0.38),
  ];

  /// [_band]와 같은 순서로, 각 밴드 스티커를 최대로 당겼을 때 선택되는 기간.
  static const List<_SummaryPeriod> periodForIndex = [
    _SummaryPeriod.sixMonths, // 기타
    _SummaryPeriod.oneYear, // 드럼
    _SummaryPeriod.all, // 보컬
  ];

  // 관객 자리(하단 결산 보고서 위쪽, 대략 y<0.80에만 오도록 배치). 티켓이
  // 늘어날 때마다 이 자리를 순서대로 채우고, fan1~9 그림도 같은 순서로
  // 돌아가며 씁니다(9장을 넘으면 다시 fan1/첫 자리부터, 즉 그대로 겹침).
  static const List<(double fx, double fy, double wf, double aspect)>
      _fanSlots = [
    (0.30, 0.545, 0.16, 0.577),
    (0.88, 0.545, 0.17, 0.420),
    (0.72, 0.575, 0.18, 0.511),
    (0.55, 0.575, 0.18, 0.488),
    (0.15, 0.60, 0.19, 0.541),
    (0.44, 0.64, 0.22, 0.574),
    (0.73, 0.66, 0.22, 0.534),
    (0.58, 0.69, 0.24, 0.700),
    (0.30, 0.705, 0.26, 0.502),
  ];

  List<_Sticker> get _fans {
    final n = ticketCount.clamp(0, _fanSlots.length);
    return [
      for (var i = 0; i < n; i++)
        _Sticker(
          'fan${i + 1}',
          _fanSlots[i].$1,
          _fanSlots[i].$2,
          _fanSlots[i].$3,
          _fanSlots[i].$4,
          crowd: true,
        ),
    ];
  }

  @override
  State<_StageCollage> createState() => _StageCollageState();

  Widget _positioned(_Sticker s, double w, double h) {
    final wpx = s.wf * w;
    final hpx = wpx / s.aspect;
    return Positioned(
      left: s.fx * w - wpx / 2,
      top: s.fy * h - hpx / 2,
      width: wpx,
      height: hpx,
      child: _image(s),
    );
  }

  Widget _image(_Sticker s) {
    Widget img = Image.asset(
      '$_dir/${s.name}.png',
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
    if (s.crowd && s.fx >= 0.5) {
      img = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..scaleByDouble(-1.0, 1.0, 1.0, 1.0),
        child: img,
      );
    }
    return img;
  }
}

class _StageCollageState extends State<_StageCollage>
    with SingleTickerProviderStateMixin {
  /// 확정된(committed) 기간(시작은 미선택=null).
  _SummaryPeriod? _committed;

  /// 지금 드래그로 향하고 있는 목표 기간. 드래그 중이 아니면 null.
  /// (committed 스티커를 다시 눌러 내리는 중이면 target도 null이지만,
  /// 이땐 [_progress] > 0으로 "진행 중"임을 구분한다.)
  _SummaryPeriod? _target;

  int? _draggingIndex;

  /// 0(=committed 그대로) ~ 1(=target으로 완전히 이동) 진행도. 드래그
  /// 중엔 손가락 위치에 맞춰 즉시 값이 바뀌고(요청4), 손을 떼면 0 또는
  /// 1로 부드럽게 안착한 뒤 committed가 갱신된다.
  late final AnimationController _progress;

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

  /// 스티커 [index]를 터치한 순간: 이미 활성화된(committed) 스티커를 다시
  /// 누른 거라면 "내리기"(target=null)로, 다른 스티커라면 "그 기간으로
  /// 올리기"(target=해당 기간)로 목표를 즉시 정한다(요청2). progress는
  /// 이어지는 드래그로 채워질 것이므로 0에서 새로 시작한다.
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

  /// [upDelta]는 위로 이동한 만큼(양수=위). 목표를 향해 "올리는" 중이면
  /// 위로 갈수록, "내리는" 중이면 아래로 갈수록 progress가 늘어난다.
  void _onDrag(int index, double upDelta, double maxOffset) {
    if (_draggingIndex != index || maxOffset <= 0) return;
    final touched = _StageCollage.periodForIndex[index];
    final raising = touched == _target;
    final signedDelta = raising ? upDelta : -upDelta;
    _progress.value = (_progress.value + signedDelta / maxOffset).clamp(0.0, 1.0);
  }

  /// 요청3: 손을 떼면 절반(0.5)을 기준으로 target까지 마저 이동(확정)하거나
  /// committed로 되돌아간다 — 중간 상태로 멈춰 있지 않는다.
  Future<void> _onDragEnd(int index) async {
    if (_draggingIndex != index) return;
    final commit = _progress.value > 0.5;
    final target = _target;
    setState(() => _draggingIndex = null);
    await _progress.animateTo(commit ? 1.0 : 0.0, curve: Curves.easeOutCubic);
    if (!mounted) return;
    setState(() {
      if (commit) _committed = target;
      _target = null;
      _progress.value = 0;
    });
    _report();
  }

  /// 밴드 [index]가 지금 [maxOffset] 중 얼마나 위로 올라와 있어야 하는지를
  /// committed/target/progress로부터 유도한다. target으로 향하는 스티커는
  /// 0→max로 올라가고, committed였다가 밀려나는 스티커는 max→0으로
  /// 내려간다 — 다른 스티커를 당기면 이전 스티커가 자동으로 내려가는
  /// 동작이 이 식 하나로 성립한다.
  double _offsetFor(int index, double maxOffset) {
    final period = _StageCollage.periodForIndex[index];
    if (period == _target) {
      return _progress.value * maxOffset;
    }
    if (period == _committed && _target != _committed) {
      return (1 - _progress.value) * maxOffset;
    }
    return 0;
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
                final stageHpx =
                    _StageCollage._stage.wf * w / _StageCollage._stage.aspect;
                final stageTop = _StageCollage._stage.fy * h - stageHpx / 2;
                final feetY = stageTop + _StageCollage._feetFrac * stageHpx;

                // 기타 기준으로 계산한 최댓값(반으로 줄임)을 3개 스티커가
                // 모두 공유한다. "끝까지"(막대 아래쪽 끝이 구멍의 아래쪽
                // 경계에 닿는) 값은 막대 길이(스티커 세로길이의 1배) 기준.
                final guitar = _StageCollage._band[0];
                final guitarHpx = (guitar.wf * w) / guitar.aspect;
                final holeHeight = context.rs(_BandPuppet.holeHeightBase);
                final guitarFullMaxOffset = (guitarHpx - holeHeight) / 2;
                final sharedMaxOffset = guitarFullMaxOffset / 2;

                // 기간 릴 위젯 위치: 원래는 무대 비율로만 정했는데, 보컬을
                // 최대로 당기면 보컬 스티커 윗부분과 겹칠 수 있어 겹치지
                // 않을 만큼 더 위여야 하면 그만큼 끌어올린다.
                final vocal = _StageCollage._band[2];
                final vocalHpx = (vocal.wf * w) / vocal.aspect;
                final vocalTopAtMax = feetY - vocalHpx - sharedMaxOffset;
                final reelH = context.rs(_PeriodReelHole.heightBase);
                const reelMargin = 6.0;
                final selectorTop = () {
                  final byStageRatio = stageTop + 0.18 * stageHpx;
                  final byVocalClearance =
                      vocalTopAtMax - reelH - context.rs(reelMargin);
                  return byStageRatio < byVocalClearance
                      ? byStageRatio
                      : byVocalClearance;
                }();

                return AnimatedBuilder(
                  animation: _progress,
                  builder: (context, _) {
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        widget._positioned(_StageCollage._stage, w, h),
                        Positioned(
                          top: selectorTop,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: _PeriodReelHole(
                              committed: _committed,
                              target: _target,
                              progress: _progress.value,
                            ),
                          ),
                        ),
                        for (var i = 0; i < _StageCollage._band.length; i++)
                          Positioned.fill(
                            child: _BandPuppet(
                              sticker: _StageCollage._band[i],
                              w: w,
                              feetY: feetY,
                              dir: _StageCollage._dir,
                              offset: _offsetFor(i, sharedMaxOffset),
                              onDragStart: () => _onDragStart(i),
                              onDragDelta: (d) => _onDrag(i, d, sharedMaxOffset),
                              onDragEnd: () => _onDragEnd(i),
                            ),
                          ),
                        for (final s in widget._fans) widget._positioned(s, w, h),
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

/// 밴드 스티커 하나(기타/드럼/보컬) + 발밑의 작은 구멍 + 그 뒤에서 함께
/// 움직이는 긴 페이지 막대. 스티커를 위로 드래그하면 꼭두각시처럼 뒤에
/// 붙은 종이 막대가 구멍 속에서 딸려 올라옵니다. 실제 위치([offset])는
/// [_StageCollageState]가 committed/target/progress로부터 계산해서
/// 내려주므로(요청4), 이 위젯은 그 값을 그대로 그리기만 한다 — 값 자체가
/// 이미 매끄럽게 이어지는 값이라 이 위젯에서 따로 애니메이션할 필요가 없다.
class _BandPuppet extends StatelessWidget {
  final _Sticker sticker;
  final double w;
  final double feetY;
  final String dir;
  final double offset;

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragDelta;
  final VoidCallback onDragEnd;

  const _BandPuppet({
    required this.sticker,
    required this.w,
    required this.feetY,
    required this.dir,
    required this.offset,
    required this.onDragStart,
    required this.onDragDelta,
    required this.onDragEnd,
  });

  /// 발밑 구멍의 세로 길이(스케일 적용 전 기준값). [_StageCollageState]도
  /// 공유 최댓값을 계산할 때 같은 값을 써야 하므로 공개 상수로 둔다.
  static const double holeHeightBase = 6;

  @override
  Widget build(BuildContext context) {
    final s = sticker;
    final wpx = s.wf * w;
    final hpx = wpx / s.aspect;

    // 막대 길이는 스티커 세로길이의 1배로, 가로 위치는 스티커 전체 중앙이
    // 아니라 얼굴의 가로 중앙([_Sticker.faceFx])에 맞춘다(얼굴이 막대에
    // 가리지 않고 보이도록). 세로 위치는 그대로 스티커의 정중앙.
    final holeWidth = wpx * 0.225;
    final holeHeight = context.rs(holeHeightBase);
    final barLength = hpx;
    final barCenterX = s.fx * w - wpx / 2 + s.faceFx * wpx;
    // 구멍의 가로 중심도 막대와 같은 위치로 맞춘다(막대가 나오는 자리와
    // 구멍이 어긋나 보이지 않도록).
    final holeLeft = barCenterX - holeWidth / 2;
    final barLeft = holeLeft;
    final holeCenterY = feetY;
    final holeBottom = holeCenterY + holeHeight / 2;
    final stickerTop = feetY - hpx - offset;
    final barTop = stickerTop + hpx / 2; // 막대 위쪽 끝 = 스티커 중앙.

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 1. 발밑 구멍(고정, 드래그해도 자리 그대로).
        Positioned(
          left: holeLeft,
          top: holeCenterY - holeHeight / 2,
          width: holeWidth,
          height: holeHeight,
          child: const IgnorePointer(child: _MiniSlotMouth()),
        ),
        // 2. 긴 페이지 막대. 스티커와 함께 움직이되, 구멍의 아래쪽 경계
        // 아래로는 절대 보이지 않도록 ClipRect로 잘라낸다.
        Positioned(
          left: barLeft,
          top: 0,
          width: holeWidth,
          height: holeBottom,
          child: ClipRect(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  top: barTop,
                  width: holeWidth,
                  height: barLength,
                  child: const IgnorePointer(child: _PageBar()),
                ),
              ],
            ),
          ),
        ),
        // 3. 스티커 본체(맨 앞, 위/아래로 드래그 가능 — 막대와 하나로 움직임).
        Positioned(
          left: s.fx * w - wpx / 2,
          top: stickerTop,
          width: wpx,
          height: hpx,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => onDragStart(),
            // 위로 드래그(primaryDelta 음수)하면 위로 이동한 양이 양수가
            // 되도록 부호를 뒤집어 보고한다.
            onVerticalDragUpdate: (d) => onDragDelta(-d.primaryDelta!),
            onVerticalDragEnd: (_) => onDragEnd(),
            onVerticalDragCancel: onDragEnd,
            child: Image.asset(
              '$dir/${s.name}.png',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ],
    );
  }
}

/// 밴드 발밑의 작은 구멍(장식). [_SlotMouth]보다 훨씬 작고 단순한 버전.
class _MiniSlotMouth extends StatelessWidget {
  const _MiniSlotMouth();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
    );
  }
}

/// 구멍 속에서 스티커를 따라 올라오는 긴 종이 막대. 결산 보고서 카드와
/// 같은 종이 색으로 통일감을 준다.
class _PageBar extends StatelessWidget {
  const _PageBar();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFBF7EC),
        border: Border.all(color: const Color(0xFF5C4033).withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// 기간(6개월/1년/전체) 표시용 작은 구멍. 직접 조작하는 위젯이 아니라,
/// 무대 위 밴드 스티커를 당겨서 바뀐 committed/target/progress를 그대로
/// 보여주기만 한다(요청4: 부모가 이미 매끄러운 값을 주므로 여기선 애니메이션
/// 컨트롤러 없이 순수하게 그리기만 함). 뒤에 숨은 "페이지"에는 -(미선택
/// 기본)/6개월/1년/전체 네 텍스트가 세로로 이어져 있고, committed→target
/// 진행도에 맞춰 그 페이지가 위아래로 넘어가며(릴처럼) 해당 텍스트가 구멍
/// 한가운데로 들어온다.
class _PeriodReelHole extends StatelessWidget {
  final _SummaryPeriod? committed;
  final _SummaryPeriod? target;
  final double progress;

  const _PeriodReelHole({
    required this.committed,
    required this.target,
    required this.progress,
  });

  // 페이지에 위에서부터 적힌 순서. index0=미선택 기본("-"), 1=6개월(기타
  // 당김), 2=1년(드럼 당김), 3=전체(보컬 당김) —
  // [_StageCollage.periodForIndex]의 매핑과 맞춘다.
  static const List<String> _labels = ['-', '6개월', '1년', '전체'];

  // 예전 기간 위젯의 작은 "페이지 조각"(segW × labelH)과 같은 크기(스케일
  // 적용 전 기준값). [_StageCollageState]도 보컬 최대 높이와 겹치지 않게
  // 위치를 잡을 때 이 값을 같이 써야 하므로 공개 상수로 둔다.
  static const double widthBase = 56;
  static const double heightBase = 34;

  static int _indexFor(_SummaryPeriod? p) => switch (p) {
        null => 0,
        _SummaryPeriod.sixMonths => 1,
        _SummaryPeriod.oneYear => 2,
        _SummaryPeriod.all => 3,
      };

  @override
  Widget build(BuildContext context) {
    final reelW = context.rs(widthBase);
    final reelH = context.rs(heightBase);
    final committedIndex = _indexFor(committed);
    final targetIndex = _indexFor(target);
    // progress=0이면 committedIndex 그대로(targetIndex가 뭐든 항이 0으로
    // 사라짐), progress=1이면 targetIndex — 두 값이 같아도(=드래그 없음)
    // 자연히 committedIndex로 고정된다.
    final reelPos = committedIndex + (targetIndex - committedIndex) * progress;

    return SizedBox(
      width: reelW,
      height: reelH,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 페이지(뒤): 4칸짜리 세로 릴을 구멍 크기만큼만 잘라서 보여준다.
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: OverflowBox(
              minHeight: 0,
              maxHeight: double.infinity,
              alignment: Alignment.topCenter,
              child: Transform.translate(
                offset: Offset(0, -reelPos * reelH),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFBF7EC),
                    border: Border.all(
                      color: const Color(0xFF5C4033).withValues(alpha: 0.25),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final label in _labels)
                        SizedBox(
                          width: reelW,
                          height: reelH,
                          child: Center(
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: context.sp(13),
                                fontWeight: FontWeight.w900,
                                color: const Color(0xFF5C4033),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 구멍 테두리(앞): 실제로 뚫린 구멍처럼 보이도록, 주변(바깥)
          // 그림자는 없애고 테두리 안쪽으로만 그림자가 지게 한다. 원형(방사형)
          // 그라데이션이 아니라 네 변에서 각각 안쪽으로 옅어지는 네모 형태의
          // 그림자([_BoxInnerShadow])를 쓴다.
          Positioned.fill(
            child: IgnorePointer(
              child: _BoxInnerShadow(
                borderRadius: 6,
                reach: reelH * 0.45,
                alpha: 0.16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 콜라주 스티커 하나.
class _Sticker {
  final String name;
  final double fx;
  final double fy;
  final double wf;
  final double aspect;
  final bool band;
  final bool crowd;

  /// 스티커 이미지 안에서 얼굴이 가로로 어디쯤 있는지(0=왼쪽 끝, 1=오른쪽
  /// 끝, 0.5=정중앙). 밴드 스티커 뒤 페이지 막대를 얼굴 중앙에 맞추는 데
  /// 쓴다(그 외 스티커는 안 쓰므로 기본값 0.5 그대로 둔다).
  final double faceFx;

  const _Sticker(
    this.name,
    this.fx,
    this.fy,
    this.wf,
    this.aspect, {
    this.band = false,
    this.crowd = false,
    this.faceFx = 0.5,
  });
}

/// 하단 슬롯("구멍")에서 위로 잡아당겨 여는 결산 보고서.
///
/// 기본(접힘) 상태에선 제목 줄만 슬롯 위로 튀어나와 있고, 위로 드래그하면
/// 보고서 내용이 다 올라옵니다(이 펼침/접힘은 기간 전환과 무관한 별개
/// 기능). 위젯의 아래쪽 끝은 항상 슬롯 아래(구멍 속)에 남아 있습니다.
///
/// 기간 전환([committedPeriod]→[targetPeriod], [progress]로 진행도 전달)은
/// 부모([_StageCollageState])가 스티커 드래그로부터 실시간으로 계산해 주는
/// 값을 그대로 반영한다 — committed/target 둘 다 있으면(다른 기간으로 바로
/// 넘어가는 경우) 앞 절반은 예전 보고서가 가라앉고 뒤 절반은 새 보고서가
/// 올라오는 하나의 연속 동작으로, 한쪽만 있으면(미선택⇄기간) 그 구간
/// 전체가 가라앉기/올라오기 하나로 처리된다.
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
            w.committedPeriod, w.committedFuture, (p * 2).clamp(0.0, 1.0));
      }
      return _CardDisplay(
          w.targetPeriod, w.targetFuture, (2 - p * 2).clamp(0.0, 1.0));
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
                            onVerticalDragUpdate: (d) => _onDragUpdate(d, bodyH),
                            onVerticalDragEnd: _onDragEnd,
                            onTap: () {
                              if (widget.progress != 0) return;
                              _c.animateTo(_c.value >= 0.5 ? 0 : 1);
                            },
                            child: display.period == null
                                ? const SizedBox.shrink()
                                : _card(context, titleH, bodyH, reveal,
                                    display.period!, display.future),
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

  Widget _card(BuildContext context, double titleH, double bodyH,
      double reveal, _SummaryPeriod period, Future<SummaryModel>? future) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFBF7EC),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: const Color(0xFF5C4033).withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
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
                                strokeWidth: 3, color: Colors.brown),
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
                      return SingleChildScrollView(child: _stats(context, data));
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
        _row(context, '🧍', '스탠딩 / 좌석',
            '${pct(d.standingRatio)} / ${pct(d.seatRatio)}'),
        _row(context, '🎬', '개막일 / 막콘',
            '${pct(d.firstConcertRatio)} / ${pct(d.lastConcertRatio)}'),
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
                      color: Colors.black.withValues(alpha: 0.15),
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
