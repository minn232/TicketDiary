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

/// 결산 조회 기간. 백엔드 `GET /summary?period=`가 받는 값(`apiValue`)과
/// 화면에 보여줄 라벨을 함께 묶어둡니다.
///
/// 백엔드가 지원하는 기간은 6개월/1년/전체뿐이라(1개월 단위 집계는 없음),
/// 화면 라벨도 "6개월"로 둡니다.
enum _SummaryPeriod {
  sixMonths('6m', '6개월'),
  oneYear('1y', '1년'),
  all('all', '전체');

  const _SummaryPeriod(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

class _SummaryScreenState extends State<SummaryScreen> {
  static const Color _paperColor = Color(0xFFF4F1E1);
  static const double _periodTagReservedHeight = 62;
  final SummaryService _summaryService = SummaryService();
  late Future<SummaryModel> _summaryFuture;
  _SummaryPeriod _selectedPeriod = _SummaryPeriod.all;

  @override
  void initState() {
    super.initState();
    _summaryFuture = _summaryService.fetchSummary(
      period: _selectedPeriod.apiValue,
    );
  }

  void _selectPeriod(_SummaryPeriod period) {
    if (period == _selectedPeriod) return;
    setState(() {
      _selectedPeriod = period;
      _summaryFuture = _summaryService.fetchSummary(period: period.apiValue);
    });
  }

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      isTabRoot: true,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.summary),
      child: Container(
        color: _paperColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 18, 18, 18),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 기간 선택 탭은 데이터 로딩 상태와 무관하게 항상 눌러서 다른
              // 기간으로 바꿀 수 있어야 하므로, FutureBuilder 바깥(위)에
              // 별도로 둡니다.
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: FutureBuilder<SummaryModel>(
                      future: _summaryFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const Center(child: CircularProgressIndicator(color: Colors.brown));
                        }
                        if (snapshot.hasError) {
                          return Center(child: Text('결산을 불러오지 못했습니다.\n${snapshot.error}', textAlign: TextAlign.center));
                        }
                        if (!snapshot.hasData) {
                          return const Center(child: Text('데이터가 없습니다.'));
                        }

                        final data = snapshot.data!;
                        return _buildSummaryContent(constraints, data);
                      },
                    ),
                  ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final period in _SummaryPeriod.values) ...[
                          if (period != _SummaryPeriod.values.first)
                            const SizedBox(width: 6),
                          _PeriodTag(
                            text: period.label,
                            selected: period == _selectedPeriod,
                            onTap: () => _selectPeriod(period),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryContent(BoxConstraints constraints, SummaryModel data) {
    // 공연 기록 자체가 없으면(AFTER_CONCERT 티켓 0건) 모든 집계값이 무의미한
    // 0이므로, 숫자 대신 "기록 없음"을 보여줍니다.
    final bool hasData = data.concertCount > 0;
    String withFallback(String value) => hasData ? value : '기록 없음';

    return SizedBox(
      height: constraints.maxHeight,
      child: Column(
        children: [
          const SizedBox(height: _periodTagReservedHeight),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(
                              child: _SummaryCard(
                                title: '간 공연 수',
                                value: withFallback('${data.concertCount}회'),
                                noteColor: const Color(0xFFFFF6A6),
                                angle: -0.010,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Expanded(
                              child: _SummaryCard(
                                title: '소비 금액',
                                value: withFallback('${data.totalSpending.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},')}원'),
                                noteColor: const Color(0xFFFFD6E8),
                                angle: 0.012,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Expanded(
                              child: _SummaryCard(
                                title: '선호 장르',
                                value: withFallback(data.favoriteGenre),
                                noteColor: const Color(0xFFCFF5E7),
                                angle: -0.008,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(
                              child: _SummaryCard(
                                title: '들은 음악 수',
                                value: withFallback('${data.songCount}곡'),
                                noteColor: const Color(0xFFD9E8FF),
                                angle: 0.010,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Expanded(
                              flex: 2,
                              child: _SummaryCard(
                                title: '관람한 아티스트',
                                noteColor: const Color(0xFFFFF1C9),
                                angle: -0.012,
                                child: _ArtistList(artists: data.visitedArtists),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 120,
                  child: Row(
                    children: [
                      Expanded(
                        // [백엔드 수정]
                        // 띄어쓰기로 바꿔서 Flutter가 화면 폭에 맞게 알아서 줄바꿈.
                        child: _SummaryCard(
                          title: '스탠딩 / 좌석 선호도',
                          value: withFallback(
                            '좌석 ${(data.seatRatio * 100).toInt()}% / 스탠딩 ${(data.standingRatio * 100).toInt()}%',
                          ),
                          center: true,
                          noteColor: const Color(0xFFE7E2FF),
                          angle: 0.010,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: _SummaryCard(
                          title: '첫콘 / 막콘 선호도',
                          value: withFallback(
                            '첫콘 ${(data.firstConcertRatio * 100).toInt()}% / 막콘 ${(data.lastConcertRatio * 100).toInt()}%',
                          ),
                          center: true,
                          noteColor: const Color(0xFFFFE7C7),
                          angle: -0.010,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 기간 선택 탭 하나(washi tape 느낌의 라벨). [selected]면 진한 가죽색으로
/// 채워 눌려있음을 보여주고, 아닌 쪽은 기존처럼 반투명 흰색으로 둡니다.
class _PeriodTag extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback? onTap;

  const _PeriodTag({required this.text, this.selected = false, this.onTap});

  static const Color _selectedColor = Color(0xFF5C4033);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Transform.rotate(
        angle: -0.10,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? _selectedColor
                : Colors.white.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.black.withValues(alpha: selected ? 0.20 : 0.35),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: selected ? 0.20 : 0.10),
                blurRadius: 8,
                offset: const Offset(2, 3),
              ),
            ],
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: context.sp(13),
              fontWeight: FontWeight.w800,
              color: selected ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final String? value;
  final Widget? child;
  final bool center;
  final Color noteColor;
  final double angle;

  const _SummaryCard({
    required this.title,
    this.value,
    this.child,
    this.center = false,
    this.noteColor = const Color(0xFFFFF6A6),
    this.angle = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    final content =
        child ??
        Text(
          value ?? '',
          textAlign: center ? TextAlign.center : TextAlign.left,
          style: TextStyle(
            fontSize: context.sp(16),
            fontWeight: FontWeight.w800,
            color: Colors.black87,
          ),
        );

    return Transform.rotate(
      angle: angle,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              color: noteColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.black.withValues(alpha: 0.12),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 12,
                  offset: const Offset(3, 5),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
              child: Column(
                crossAxisAlignment: center
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    textAlign: center ? TextAlign.center : TextAlign.left,
                    style: TextStyle(
                      fontSize: context.sp(12),
                      fontWeight: FontWeight.w900,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Align(
                      alignment: center
                          ? Alignment.center
                          : Alignment.centerLeft,
                      child: content,
                    ),
                  ),
                ],
              ),
            ),
          ),

          /// 상단 테이프 느낌
          Positioned(
            top: -8,
            left: 22,
            right: 22,
            child: Container(
              height: 16,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.50),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.06),
                  width: 1,
                ),
              ),
            ),
          ),

          /// 접힌 모서리 (오른쪽 위)
          Positioned(
            top: 0,
            right: 0,
            child: ClipPath(
              clipper: _PostItCornerClipper(),
              child: Container(
                width: 28,
                height: 28,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 포스트잇 접힌 모서리(오른쪽 위) 모양을 만들기 위한 클리퍼
class _PostItCornerClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, 0)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _ArtistList extends StatelessWidget {
  final List<String> artists;

  const _ArtistList({required this.artists});

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) {
      return Text(
        '기록 없음',
        style: TextStyle(fontSize: context.sp(13), color: Colors.black38),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final a in artists.take(6))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '• $a',
              style: TextStyle(
                fontSize: context.sp(14),
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
          ),
      ],
    );
  }
}
