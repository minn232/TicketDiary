import 'dart:async';
import 'package:flutter/material.dart';
import '../models/summary_map.dart';
import '../services/summary_service.dart';
import '../services/ticket_refresh_bus.dart';
import '../widgets/summary_region_map.dart';
import '../widgets/summary_report_drawer.dart';
import '../widgets/diary_landscape_cover_panel.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import 'diary_screen.dart' show buildUpcomingTicketLandscapePanel;

const Color _summaryPageColor = Color(0xFFCEB99B);

enum _SummaryPeriod {
  sixMonths('6개월', '6m'),
  oneYear('1년', '1y'),
  all('전체', 'all');

  const _SummaryPeriod(this.label, this.api);
  final String label;
  final String api;
}

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key, this.service});
  final SummaryService? service;
  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  late final _service = widget.service ?? SummaryService();
  late final Future<SummaryMapData> _map = SummaryMapData.load();
  late Future<RegionalSummary> _summary;
  Future<SummaryModel>? _report;
  int _reportRevision = 0;
  _SummaryPeriod _period = _SummaryPeriod.all;

  Future<T> _observe<T>(Future<T> future) {
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    return future;
  }

  @override
  void initState() {
    super.initState();
    _summary = _observe(_service.fetchRegions());
    TicketRefreshBus.tick.addListener(_reload);
  }

  @override
  void dispose() {
    TicketRefreshBus.tick.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    setState(() {
      _summary = _observe(_service.fetchRegions(period: _period.api));
      if (_report != null) {
        _report = _observe(_service.fetchSummary(period: _period.api));
      }
    });
  }

  void _selectPeriod(_SummaryPeriod period) {
    setState(() {
      _period = period;
      _summary = _observe(_service.fetchRegions(period: period.api));
      _report = _observe(_service.fetchSummary(period: period.api));
      // Every selection, including the current period, presents a fresh handle.
      _reportRevision++;
    });
  }

  @override
  Widget build(BuildContext context) => DiaryPageFrame(
    isTabRoot: true,
    sideTabs: buildDiarySideTabs(context, active: DiaryTab.summary),
    landscapeCompanionPanel: DiaryLandscapeCoverPanel(
      child: buildUpcomingTicketLandscapePanel(),
    ),
    child: ColoredBox(
      color: _summaryPageColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
        child: Column(
          children: [
            Row(
              children: [
                for (final period in _SummaryPeriod.values)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Semantics(
                        selected: _period == period,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: () => _selectPeriod(period),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(24),
                                color: period == _period
                                    ? summaryInk
                                    : summaryPaper,
                              ),
                              child: Text(
                                period.label,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: period == _period
                                      ? summaryPaper
                                      : summaryInk,
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
            const SizedBox(height: 5),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: _report == null ? 0 : 62,
                      ),
                      child: FutureBuilder<SummaryMapData>(
                        future: _map,
                        builder: (context, map) {
                          if (map.hasError) {
                            return const Center(
                              child: Text(
                                '지도를 표시할 수 없어요',
                                style: TextStyle(color: summaryInk),
                              ),
                            );
                          }
                          if (!map.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(
                                color: summaryInk,
                              ),
                            );
                          }
                          return FutureBuilder<RegionalSummary>(
                            future: _summary,
                            builder: (context, snapshot) {
                              final ready =
                                  snapshot.connectionState ==
                                      ConnectionState.done &&
                                  snapshot.hasData;
                              final data = ready ? snapshot.data : null;
                              final counts = data == null
                                  ? null
                                  : map.data!.countVisits(data.visits);
                              final matched = counts == null
                                  ? 0
                                  : map.data!
                                        .children(null)
                                        .fold<int>(
                                          0,
                                          (n, r) => n + (counts[r.id] ?? 0),
                                        );
                              return SummaryRegionMap(
                                data: map.data!,
                                counts: counts,
                                partial: data != null && data.total > matched,
                                countStatus: snapshot.hasError
                                    ? '조회하지 못했어요'
                                    : null,
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  if (_report != null)
                    Positioned.fill(
                      child: SummaryReportDrawer(
                        key: ValueKey(_reportRevision),
                        periodLabel: _period.label,
                        future: _report!,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
