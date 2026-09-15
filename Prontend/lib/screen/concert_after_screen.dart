import 'package:flutter/material.dart';

import '../models/ticket_info.dart';
import '../widgets/concert_after_page_contents.dart';

/// 별도 화면으로 진입할 때도 한 장의 공연 후 기록 페이지만 표시합니다.
class ConcertAfterScreen extends StatelessWidget {
  final String concertTitle;

  /// 스캔/서버 조회로 채워진 티켓 정보. `concertId`가 있어야 "실제 셋리스트"를,
  /// `ticketId`가 있어야 후기/사진 편집을 서버에 반영할 수 있습니다(둘 다
  /// 없으면 로컬 예시 티켓이라 조회/편집 없이 안내 문구만 표시).
  final TicketInfo? ticketInfo;

  const ConcertAfterScreen({
    super.key,
    required this.concertTitle,
    this.ticketInfo,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF30271F),
      appBar: AppBar(title: const Text('공연 후')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ConcertAfterPageContents(
              concertTitle: concertTitle,
              ticketInfo: ticketInfo,
              showCloseHint: false,
            ),
          ),
        ),
      ),
    );
  }
}
