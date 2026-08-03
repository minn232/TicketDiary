import 'package:flutter/material.dart';

import '../models/ticket_info.dart';
import '../widgets/concert_after_page_contents.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/poster_background.dart';

/// 공연 후 상세 페이지.
///
/// [ConcertBeforeScreen]과 같은 구조(얇은 [DiaryPageFrame] 래퍼)입니다.
/// 실제 다이어리 화면에서는 [ConcertAfterOverlay]가 이 화면을 대신해
/// 티켓 위치에서 자연스럽게 확장되는 형태로 보여주고, 여기 [ConcertAfterScreen]은
/// 일반 push(딥링크 등)로 진입할 때를 위한 화면입니다.
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
    return DiaryPageFrame(
      // 다른 메인 페이지(다이어리/소식/결산/설정)와 같은 규격(diaryAspectRatio)을 씁니다.
      sideTabs: buildDiarySideTabs(context, active: null),
      child: Stack(
        children: [
          // 공연 포스터를 페이지 배경 전체에 살짝 투명하게 겹칩니다.
          // DiaryPageFrame의 페이지 컨테이너가 이미 이 child를 페이지와
          // 같은 모양(오른쪽만 둥근 모서리)으로 clip해주므로, 여기서는
          // 그냥 꽉 채우기만 하면 됩니다.
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.4,
                child: PosterBackground(imageUrl: ticketInfo?.posterImageUrl),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 20, 18, 18),
            child: ConcertAfterPageContents(
              concertTitle: concertTitle,
              ticketInfo: ticketInfo,
              // 스크린 버전에서는 "닫기 힌트"가 UX와 안 맞을 수 있어 숨깁니다.
              showCloseHint: false,
            ),
          ),
        ],
      ),
    );
  }
}
