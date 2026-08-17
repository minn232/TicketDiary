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

/// 결산 조회 기간. 무대 안 날짜 버튼을 누를 때마다 순환합니다(6개월→1년→전체).
enum _SummaryPeriod {
  sixMonths('6개월', '6m'),
  oneYear('1년', '1y'),
  all('전체', 'all');

  const _SummaryPeriod(this.label, this.api);

  final String label;
  final String api;

  _SummaryPeriod get next =>
      _SummaryPeriod.values[(index + 1) % _SummaryPeriod.values.length];
}

class _SummaryScreenState extends State<SummaryScreen> {
  static const Color _paperColor = Color(0xFFF4F1E1);
  final SummaryService _service = SummaryService();

  _SummaryPeriod _period = _SummaryPeriod.sixMonths;
  late Future<SummaryModel> _future;
  bool _showSummary = false;

  @override
  void initState() {
    super.initState();
    _future = _service.fetchSummary(period: _period.api);
  }

  /// 무대 안 날짜 버튼: 다음 기간으로 순환하고 그 기간의 결산을 다시 불러옵니다.
  void _cyclePeriod() {
    setState(() {
      _period = _period.next;
      _future = _service.fetchSummary(period: _period.api);
    });
  }

  void _openSummary() => setState(() => _showSummary = true);
  void _closeSummary() => setState(() => _showSummary = false);

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      isTabRoot: true,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.summary),
      child: Container(
        color: _paperColor,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: _StageCollage(
                periodLabel: _period.label,
                onCyclePeriod: _cyclePeriod,
                onVocalTap: _openSummary,
              ),
            ),
            // 보컬을 누르면: 현재 기간의 결산 텍스트가 확대되며 나옵니다.
            if (_showSummary)
              _SummaryOverlay(
                periodLabel: _period.label,
                future: _future,
                onClose: _closeSummary,
              ),
          ],
        ),
      ),
    );
  }
}

/// 무대 공연 장면(스티커 콜라주). 무대 스티커 안쪽 빈 공간에 날짜 순환 버튼을
/// 얹고, 밴드(기타·드럼·보컬)는 무대 플랫폼 위에 발을 맞춰 세웁니다. 보컬을
/// 누르면 [onVocalTap]이 불립니다.
class _StageCollage extends StatelessWidget {
  final String periodLabel;
  final VoidCallback onCyclePeriod;
  final VoidCallback onVocalTap;

  const _StageCollage({
    required this.periodLabel,
    required this.onCyclePeriod,
    required this.onVocalTap,
  });

  static const String _dir = 'assets/images/summary';

  /// 무대 스티커 안에서 공연자가 서는 플랫폼 상단(발이 놓일 높이, 0~1).
  static const double _feetFrac = 0.73;

  static const _Sticker _stage = _Sticker('stage', 0.50, 0.30, 1.00, 0.881);

  /// 무대 위 밴드(플랫폼에 발을 맞춰 세움). 보컬은 최상단 + 탭 대상.
  static const List<_Sticker> _band = [
    _Sticker('guitar', 0.20, 0, 0.30, 0.688, band: true),
    _Sticker('drum', 0.74, 0, 0.42, 1.154, band: true),
    _Sticker('vocal', 0.50, 0, 0.364, 0.669, band: true, vocal: true),
  ];

  /// 관객: 관객 영역 안 무작위 위치(뒤→앞). fx≥0.5면 좌우반전(안쪽을 보게).
  static const List<_Sticker> _fans = [
    _Sticker('fan7', 0.333, 0.624, 0.189, 0.577, crowd: true),
    _Sticker('fan8', 0.909, 0.625, 0.203, 0.420, crowd: true),
    _Sticker('fan5', 0.744, 0.659, 0.220, 0.511, crowd: true),
    _Sticker('fan2', 0.572, 0.661, 0.220, 0.488, crowd: true),
    _Sticker('fan3', 0.167, 0.700, 0.226, 0.541, crowd: true),
    _Sticker('fan1', 0.461, 0.785, 0.292, 0.574, crowd: true),
    _Sticker('fan4', 0.754, 0.829, 0.287, 0.534, crowd: true),
    _Sticker('fan9', 0.594, 0.904, 0.330, 0.700, crowd: true),
    _Sticker('fan6', 0.311, 0.920, 0.354, 0.502, crowd: true),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, full) {
        // 배치 영역 여백: 좌·우·하 = 바인더 은색 막대 길이의 절반, 상단은 3배.
        final halfBar =
            (full.maxWidth * DiaryPageFrame.binderBarWidthRatio + 5) / 2;
        return Padding(
          padding: EdgeInsets.only(
            left: halfBar,
            right: halfBar,
            bottom: halfBar,
            top: halfBar * 3,
          ),
          child: ClipRect(
            child: LayoutBuilder(
              builder: (context, c) {
                final w = c.maxWidth;
                final h = c.maxHeight;
                // 무대 기하 → 플랫폼 발 높이 + 날짜 버튼 위치.
                final stageHpx = _stage.wf * w / _stage.aspect;
                final stageTop = _stage.fy * h - stageHpx / 2;
                final feetY = stageTop + _feetFrac * stageHpx;
                final dateBtnTop = stageTop + 0.25 * stageHpx - 24;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _positioned(_stage, w, h),
                    // 무대 빈 공간의 날짜 순환 버튼.
                    Positioned(
                      top: dateBtnTop,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: _DateButton(
                          label: periodLabel,
                          onTap: onCyclePeriod,
                        ),
                      ),
                    ),
                    for (final s in _band) _positionedBand(s, w, feetY),
                    for (final s in _fans) _positioned(s, w, h),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// 일반 배치(무대·관객): 중심 fx/fy. 관객이면서 오른쪽이면 좌우반전.
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

  /// 밴드 배치: 가로는 fx, 세로는 발(스티커 하단)이 무대 플랫폼 [feetY]에 닿게.
  Widget _positionedBand(_Sticker s, double w, double feetY) {
    final wpx = s.wf * w;
    final hpx = wpx / s.aspect;
    Widget child = _image(s);
    if (s.vocal) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onVocalTap,
        child: child,
      );
    }
    return Positioned(
      left: s.fx * w - wpx / 2,
      top: feetY - hpx,
      width: wpx,
      height: hpx,
      child: child,
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

/// 무대 안 날짜 순환 버튼. 현재 기간 라벨을 보여주고, 누르면 다음 기간으로.
class _DateButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _DateButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rs(16),
          vertical: context.rs(9),
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF5C4033),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_today_rounded,
                size: context.sp(14), color: Colors.white),
            SizedBox(width: context.rs(7)),
            Text(
              label,
              style: TextStyle(
                fontSize: context.sp(15),
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
            SizedBox(width: context.rs(5)),
            Icon(Icons.unfold_more_rounded,
                size: context.sp(14),
                color: Colors.white.withValues(alpha: 0.8)),
          ],
        ),
      ),
    );
  }
}

/// 콜라주 스티커 하나. [fx],[fy] 중심 위치(0~1), [wf] 영역 너비 대비 너비,
/// [aspect] 고유 비율(w/h). [band]는 무대 위 밴드(발 정렬), [vocal]은 탭 대상,
/// [crowd]는 관객(오른쪽이면 좌우반전).
class _Sticker {
  final String name;
  final double fx;
  final double fy;
  final double wf;
  final double aspect;
  final bool band;
  final bool vocal;
  final bool crowd;

  const _Sticker(
    this.name,
    this.fx,
    this.fy,
    this.wf,
    this.aspect, {
    this.band = false,
    this.vocal = false,
    this.crowd = false,
  });
}

/// 보컬을 눌렀을 때 확대되며 나오는 결산 오버레이. 어두운 배경 + 가운데에서
/// 팝 하고 커지는 결산 카드. 배경(또는 닫기 버튼)을 누르면 닫힙니다.
class _SummaryOverlay extends StatelessWidget {
  final String periodLabel;
  final Future<SummaryModel> future;
  final VoidCallback onClose;

  const _SummaryOverlay({
    required this.periodLabel,
    required this.future,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        children: [
          // 어두운 배경(탭하면 닫힘).
          Positioned.fill(
            child: GestureDetector(
              onTap: onClose,
              child: Container(color: Colors.black.withValues(alpha: 0.55)),
            ),
          ),
          // 확대되며 나오는 결산 카드.
          Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 340),
              curve: Curves.easeOutBack,
              builder: (context, t, child) => Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.scale(scale: 0.4 + 0.6 * t, child: child),
              ),
              child: _SummaryCard(
                periodLabel: periodLabel,
                future: future,
                onClose: onClose,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 결산 내용 카드(단순·직관적). 기간 제목 + 핵심 통계 몇 줄.
class _SummaryCard extends StatelessWidget {
  final String periodLabel;
  final Future<SummaryModel> future;
  final VoidCallback onClose;

  const _SummaryCard({
    required this.periodLabel,
    required this.future,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: (MediaQuery.sizeOf(context).width * 0.8).clamp(240.0, 360.0),
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
      decoration: BoxDecoration(
        color: const Color(0xFFFBF7EC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF5C4033).withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '$periodLabel 결산',
                style: TextStyle(
                  fontSize: context.sp(20),
                  fontWeight: FontWeight.w900,
                  color: const Color(0xFF5C4033),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onClose,
                behavior: HitTestBehavior.opaque,
                child: Icon(Icons.close_rounded,
                    size: context.sp(22), color: Colors.black45),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FutureBuilder<SummaryModel>(
            future: future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: CircularProgressIndicator(color: Colors.brown),
                  ),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    '결산을 불러오지 못했어요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: context.sp(14),
                      color: Colors.black54,
                    ),
                  ),
                );
              }
              final data = snap.data;
              if (data == null || data.concertCount == 0) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    '아직 이 기간의 공연 기록이 없어요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: context.sp(14),
                      color: Colors.black54,
                    ),
                  ),
                );
              }
              return _stats(context, data);
            },
          ),
        ],
      ),
    );
  }

  Widget _stats(BuildContext context, SummaryModel d) {
    final spending = d.totalSpending.toString().replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
    final topArtist = d.visitedArtists.isNotEmpty ? d.visitedArtists.first : null;
    final standing = (d.standingRatio * 100).round();
    final seat = (d.seatRatio * 100).round();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _row(context, '🎫', '본 공연', '${d.concertCount}회'),
        _row(context, '🎤', '관람 아티스트',
            '${d.visitedArtists.length}팀${topArtist != null ? ' · 최애 ${topArtist.name}' : ''}'),
        _row(context, '🎵', '들은 곡', '${d.songCount}곡'),
        _row(context, '💰', '쓴 금액', '$spending원'),
        _row(context, '🎸', '최애 장르', d.favoriteGenre),
        _row(context, '🧍', '스탠딩 · 좌석', '$standing% · $seat%'),
      ],
    );
  }

  Widget _row(BuildContext context, String emoji, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(emoji, style: TextStyle(fontSize: context.sp(17))),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: context.sp(14),
              fontWeight: FontWeight.w700,
              color: Colors.black.withValues(alpha: 0.6),
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.sp(15),
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
