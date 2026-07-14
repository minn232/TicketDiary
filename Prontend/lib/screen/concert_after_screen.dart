import 'package:flutter/material.dart';
import '../models/ticket_info.dart';
import '../services/api_client.dart';
import '../services/concert_detail_service.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';

/// 공연 후 상세 페이지(스크린샷의 2x2 그리드 레이아웃)
class ConcertAfterScreen extends StatelessWidget {
  final String concertTitle;

  /// 스캔/서버 조회로 채워진 티켓 정보. `concertId`가 있어야 "실제 셋리스트"를
  /// 서버에서 불러올 수 있습니다(없으면 안내 문구만 표시).
  final TicketInfo? ticketInfo;

  const ConcertAfterScreen({
    super.key,
    required this.concertTitle,
    this.ticketInfo,
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
                  Expanded(
                    child: _PostItSlot(
                      title: "실제\n셋리스트",
                      noteColor: const Color(0xFFD9E8FF),
                      angle: -0.012,
                      child: _RealSetlistContent(
                        concertId: ticketInfo?.concertId,
                      ),
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

/// "실제 셋리스트" 포스트잇 안에 들어가는 내용. concertId가 있으면
/// `GET /concerts/{concertId}/setlist`로 실제 데이터를 불러오고, 없거나
/// 아직 등록 전이면 기존과 같은 라벨 텍스트를 보여줍니다.
class _RealSetlistContent extends StatefulWidget {
  final String? concertId;

  const _RealSetlistContent({required this.concertId});

  @override
  State<_RealSetlistContent> createState() => _RealSetlistContentState();
}

class _RealSetlistContentState extends State<_RealSetlistContent> {
  final ConcertDetailService _service = ConcertDetailService();
  List<String>? _songs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final concertId = widget.concertId;
    if (concertId == null) return;
    try {
      final res = await _service.getRealSetlist(concertId);
      if (!mounted) return;
      setState(() {
        _songs = res.songs
            .map((s) => s.encore ? '${s.name} (앵콜)' : s.name)
            .toList();
      });
    } on ApiException catch (_) {
      // 아직 등록 안 됐으면(404) 조용히 라벨 텍스트를 유지합니다.
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final songs = _songs;
    if (songs == null || songs.isEmpty) {
      return const Text(
        "실제\n셋리스트",
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: Colors.black87,
          height: 1.2,
          letterSpacing: 0.5,
        ),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '실제 셋리스트',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          for (final song in songs)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                song,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }
}

/// 공연후 화면의 2x2 영역에 사용하는 포스트잇 카드
class _PostItSlot extends StatelessWidget {
  final String title;
  final Color noteColor;
  final double angle;

  /// 지정하면 가운데 제목 텍스트 대신 이 위젯을 보여줍니다(예: 실제 데이터로
  /// 채워진 셋리스트). 지정하지 않으면 기존처럼 [title] 텍스트만 표시합니다.
  final Widget? child;

  const _PostItSlot({
    required this.title,
    required this.noteColor,
    required this.angle,
    this.child,
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
                child:
                    child ??
                    Text(
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
