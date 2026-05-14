import 'package:flutter/material.dart';
import 'widgets/diary_page_frame.dart';
import 'widgets/diary_tabs.dart';

/// 공연 후 상세 페이지(스크린샷의 2x2 그리드 레이아웃)
class ConcertAfterScreen extends StatelessWidget {
  final String concertTitle;

  const ConcertAfterScreen({
    super.key,
    required this.concertTitle,
  });

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      sideTabs: buildDiarySideTabs(context, active: null),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 18, 18, 18),
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  const Expanded(
                    child: _PostItSlot(
                      title: "사진",
                      noteColor: Color(0xFFFFF6A6),
                      angle: -0.010,
                    ),
                  ),
                  const SizedBox(width: 18),
                  const Expanded(
                    child: _PostItSlot(
                      title: "공연\n소감",
                      noteColor: Color(0xFFFFD6E8),
                      angle: 0.012,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: Row(
                children: [
                  const Expanded(
                    child: _PostItSlot(
                      title: "업적\n도장",
                      noteColor: Color(0xFFCFF5E7),
                      angle: 0.010,
                    ),
                  ),
                  const SizedBox(width: 18),
                  const Expanded(
                    child: _PostItSlot(
                      title: "실제\n셋리스트",
                      noteColor: Color(0xFFD9E8FF),
                      angle: -0.012,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 공연후 화면의 2x2 영역에 사용하는 포스트잇 카드
class _PostItSlot extends StatelessWidget {
  final String title;
  final Color noteColor;
  final double angle;

  const _PostItSlot({
    required this.title,
    required this.noteColor,
    required this.angle,
  });

  @override
  Widget build(BuildContext context) {
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
              padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
              child: Center(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                    height: 1.2,
                    letterSpacing: 0.5,
                  ),
                ),
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
                color: Colors.white.withValues(alpha: 0.5),
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

