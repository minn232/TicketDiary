import 'dart:convert';
import 'package:flutter/material.dart';

import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';

/// [준비 1] 결산 데이터 모델
class SummaryModel {
  final int concertCount;
  final int totalSpending;
  final int songCount;
  final String favoriteGenre;
  final List<String> visitedArtists;
  final double standingRatio;
  final double seatRatio;
  final double firstConcertRatio;
  final double lastConcertRatio;

  SummaryModel({
    required this.concertCount,
    required this.totalSpending,
    required this.songCount,
    required this.favoriteGenre,
    required this.visitedArtists,
    required this.standingRatio,
    required this.seatRatio,
    required this.firstConcertRatio,
    required this.lastConcertRatio,
  });

  factory SummaryModel.fromJson(Map<String, dynamic> json) {
    return SummaryModel(
      concertCount: json['concert_count'] ?? 0,
      totalSpending: json['total_spending'] ?? 0,
      songCount: json['song_count'] ?? 0,
      favoriteGenre: json['favorite_genre'] ?? '-',
      visitedArtists: List<String>.from(json['visited_artists'] ?? []),
      standingRatio: (json['standing_ratio'] ?? 0.0).toDouble(),
      seatRatio: (json['seat_ratio'] ?? 0.0).toDouble(),
      firstConcertRatio: (json['first_concert_ratio'] ?? 0.0).toDouble(),
      lastConcertRatio: (json['last_concert_ratio'] ?? 0.0).toDouble(),
    );
  }
}

/// [준비 2] API 서비스 레이어
class SummaryApiService {
  static Future<SummaryModel> fetchSummary() async {
    // 가짜 JSON 데이터 (백엔드 연동 전까지 비워둡니다 - 모든 값 0 또는 빈 값 처리)
    // 테스트가 필요하다면 아래 주석을 풀고 실제 값을 넣어보세요.
    final String mockJsonResponse = '''
    {
      "concert_count": 0,
      "total_spending": 0,
      "song_count": 0,
      "favorite_genre": "-",
      "visited_artists": [],
      "standing_ratio": 0.0,
      "seat_ratio": 0.0,
      "first_concert_ratio": 0.0,
      "last_concert_ratio": 0.0
    }
    ''';

    final Map<String, dynamic> data = jsonDecode(mockJsonResponse);
    return SummaryModel.fromJson(data);
  }
}

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  static const Color _paperColor = Color(0xFFF4F1E1);
  static const double _periodTagReservedHeight = 62;
  late Future<SummaryModel> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = SummaryApiService.fetchSummary();
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
              return FutureBuilder<SummaryModel>(
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
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryContent(BoxConstraints constraints, SummaryModel data) {
    return SizedBox(
      height: constraints.maxHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
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
                                    value: '${data.concertCount}회',
                                    noteColor: const Color(0xFFFFF6A6),
                                    angle: -0.010,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Expanded(
                                  child: _SummaryCard(
                                    title: '소비 금액',
                                    value: '${data.totalSpending.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},')}원',
                                    noteColor: const Color(0xFFFFD6E8),
                                    angle: 0.012,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Expanded(
                                  child: _SummaryCard(
                                    title: '선호 장르',
                                    value: data.favoriteGenre,
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
                                    value: '${data.songCount}곡',
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
                            child: _SummaryCard(
                              title: '스탠딩 / 좌석\n선호도',
                              value: '좌석 ${(data.seatRatio * 100).toInt()}% / 스탠딩 ${(data.standingRatio * 100).toInt()}%',
                              center: true,
                              noteColor: const Color(0xFFE7E2FF),
                              angle: 0.010,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: _SummaryCard(
                              title: '첫콘 / 막콘\n선호도',
                              value: '첫콘 ${(data.firstConcertRatio * 100).toInt()}% / 막콘 ${(data.lastConcertRatio * 100).toInt()}%',
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
          Positioned(top: 6, left: 6, child: const _PeriodTag(text: '전체')),
        ],
      ),
    );
  }
}

class _PeriodTag extends StatelessWidget {
  final String text;

  const _PeriodTag({required this.text});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.10,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.black.withValues(alpha: 0.35),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 8,
              offset: const Offset(2, 3),
            ),
          ],
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: Colors.black87,
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
          style: const TextStyle(
            fontSize: 16,
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
                    style: const TextStyle(
                      fontSize: 12,
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
      return const Text(
        '기록이 없습니다.',
        style: TextStyle(fontSize: 13, color: Colors.black38),
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
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
          ),
      ],
    );
  }
}
