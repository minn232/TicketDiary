import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/summary_service.dart';
import 'summary_region_map.dart' show summaryInk, summaryPaper;

/// A paper report emerging from the bottom slot. The same scroll controller
/// first expands the paper, then scrolls its contents on smaller screens.
class SummaryReportDrawer extends StatefulWidget {
  final String periodLabel;
  final Future<SummaryModel> future;
  const SummaryReportDrawer({
    super.key,
    required this.periodLabel,
    required this.future,
  });
  @override
  State<SummaryReportDrawer> createState() => _SummaryReportDrawerState();
}

class _SummaryReportDrawerState extends State<SummaryReportDrawer> {
  final _controller = DraggableScrollableController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final minimum = (60 / c.maxHeight).clamp(.08, .3);
      final maximum = math.max(minimum, .86);
      return DraggableScrollableSheet(
        key: const ValueKey('summary-report-sheet'),
        controller: _controller,
        initialChildSize: minimum,
        minChildSize: minimum,
        maxChildSize: maximum,
        snap: true,
        snapSizes: [minimum, maximum],
        shouldCloseOnMinExtent: false,
        builder: (context, scrollController) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: summaryPaper,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            border: Border.all(color: summaryInk.withValues(alpha: .28)),
            boxShadow: [
              BoxShadow(
                color: summaryInk.withValues(alpha: .2),
                blurRadius: 10,
                offset: const Offset(0, -3),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.zero,
            physics: const ClampingScrollPhysics(),
            children: [
              Semantics(
                button: true,
                label: '${widget.periodLabel} 결산 보고서 펼치기',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (_controller.isAttached) {
                      _controller.animateTo(
                        _controller.size > minimum + .1 ? minimum : maximum,
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                      );
                    }
                  },
                  child: SizedBox(
                    key: const ValueKey('summary-report-handle'),
                    height: 59,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: summaryInk.withValues(alpha: .35),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${widget.periodLabel} 결산 보고서',
                          style: const TextStyle(
                            color: summaryInk,
                            fontWeight: FontWeight.w700,
                            fontSize: 17,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              FutureBuilder<SummaryModel>(
                future: widget.future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(
                        child: Text(
                          '보고서를 불러오는 중…',
                          style: TextStyle(color: summaryInk),
                        ),
                      ),
                    );
                  }
                  if (snapshot.hasError || !snapshot.hasData) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '보고서를 불러오지 못했어요.\n기간을 다시 선택해 주세요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: summaryInk),
                      ),
                    );
                  }
                  final data = snapshot.data!;
                  String ratio(double value) => '${(value * 100).round()}%';
                  final spending = data.totalSpending
                      .toString()
                      .replaceAllMapped(
                        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
                        (m) => '${m[1]},',
                      );
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
                    child: Column(
                      children: [
                        if (data.concertCount == 0)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text(
                              '아직 이 기간의 관람 기록이 없어요',
                              style: TextStyle(color: summaryInk),
                            ),
                          ),
                        _row('총 관람 횟수', '${data.concertCount}회'),
                        _row('총 지출 금액', '$spending원'),
                        _row('가장 많이 본 장르', data.favoriteGenre),
                        _row('들은 곡', '${data.songCount}곡'),
                        _row(
                          '스탠딩 / 좌석',
                          '${ratio(data.standingRatio)} / ${ratio(data.seatRatio)}',
                        ),
                        _row(
                          '첫 공연 / 마지막 공연',
                          '${ratio(data.firstConcertRatio)} / ${ratio(data.lastConcertRatio)}',
                        ),
                        if (data.visitedArtists.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '관람 아티스트',
                              style: TextStyle(
                                color: summaryInk,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          for (final artist in data.visitedArtists)
                            _row(artist.name, '${artist.count}회'),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: summaryInk.withValues(alpha: .78),
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              color: summaryInk,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}
