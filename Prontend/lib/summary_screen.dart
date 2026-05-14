import 'package:flutter/material.dart';

import 'widgets/diary_page_frame.dart';
import 'widgets/diary_tabs.dart';

class SummaryScreen extends StatelessWidget {
  const SummaryScreen({super.key});

  static const double _periodTagReservedHeight = 62;

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.summary),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 18, 18, 18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SizedBox(
              height: constraints.maxHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  /// 실제 컨텐츠
                  Column(
                    children: [
                      /// [기간] 태그가 상단 포스트잇과 겹치지 않도록 공간 확보
                      const SizedBox(height: _periodTagReservedHeight),
                      Expanded(
                        child: Column(
                          children: [
                            /// 상단 2열 블록
                            Expanded(
                              child: Row(
                                children: [
                                  /// 왼쪽 열(3개)
                                  Expanded(
                                    child: Column(
                                      children: const [
                                        Expanded(
                                          child: _SummaryCard(
                                            title: '간 공연 수',
                                            value: '5회',
                                            noteColor: Color(0xFFFFF6A6),
                                            angle: -0.010,
                                          ),
                                        ),
                                        SizedBox(height: 14),
                                        Expanded(
                                          child: _SummaryCard(
                                            title: '소비 금액',
                                            value: '150,000원',
                                            noteColor: Color(0xFFFFD6E8),
                                            angle: 0.012,
                                          ),
                                        ),
                                        SizedBox(height: 14),
                                        Expanded(
                                          child: _SummaryCard(
                                            title: '선호 장르',
                                            value: 'Rock / Indie',
                                            noteColor: Color(0xFFCFF5E7),
                                            angle: -0.008,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 14),

                                  /// 오른쪽 열(2개: 위 작은 / 아래 큰)
                                  Expanded(
                                    child: Column(
                                      children: const [
                                        Expanded(
                                          child: _SummaryCard(
                                            title: '들은 음악 수',
                                            value: '123곡',
                                            noteColor: Color(0xFFD9E8FF),
                                            angle: 0.010,
                                          ),
                                        ),
                                        SizedBox(height: 14),
                                        Expanded(
                                          flex: 2,
                                          child: _SummaryCard(
                                            title: '관람한 아티스트',
                                            noteColor: Color(0xFFFFF1C9),
                                            angle: -0.012,
                                            child: _ArtistList(
                                              artists: [
                                                'Artist A',
                                                'Artist B',
                                                'Artist C',
                                                'Artist D',
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 14),

                            /// 하단 2개 넓은 카드
                            const SizedBox(
                              height: 120,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: _SummaryCard(
                                      title: '스탠딩 / 좌석\n선호도',
                                      value: '좌석 70% / 스탠딩 30%',
                                      center: true,
                                      noteColor: Color(0xFFE7E2FF),
                                      angle: 0.010,
                                    ),
                                  ),
                                  SizedBox(width: 14),
                                  Expanded(
                                    child: _SummaryCard(
                                      title: '첫콘 / 막콘\n선호도',
                                      value: '첫콘 40% / 막콘 60%',
                                      center: true,
                                      noteColor: Color(0xFFFFE7C7),
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

                  /// 기간 태그(좌상단)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _PeriodTag(text: '기간'),
                  ),
                ],
              ),
            );
          },
        ),
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
          border: Border.all(color: Colors.black.withValues(alpha: 0.35), width: 1.2),
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
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.black87),
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
    final content = child ??
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
                crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
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
                      alignment: center ? Alignment.center : Alignment.centerLeft,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final a in artists.take(6))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '• $a',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.black87),
            ),
          ),
      ],
    );
  }
}

