import 'package:flutter/material.dart';
import '../widgets/diary_page_frame.dart';
import '../widgets/diary_tabs.dart';
import '../widgets/concert_before_page_contents.dart';

/// 기본 StatelessWidget을 상속받음.
/// UI를 일단 고정시킬거기 때문에 사용.
/// 공연 전 상세 정보 페이지를 표시하는 화면.
class ConcertBeforeScreen extends StatelessWidget {
  /// 공연 전 class
  final String concertTitle;

  /// 공연의 제목을 저장하는 변수. final로 변경 불가능을 명시

  /// 생성자에서 공연 제목을 받아옴.
  const ConcertBeforeScreen({
    super.key,

    /// flutter에서 위젯을 식별하기 위한 key
    required this.concertTitle,

    /// 공연 제목은 필수적으로 받기 위해 required 사용
  });

  /*
  *     공연 정보의 다이어리 페이지, 인덱스 탭, 왼쪽 바인더 링의 배치
  *     공연 정보 상세 페이지를 구성하는 부분.
   */

  @override
  Widget build(BuildContext context) {
    /// 공연 전 화면의 UI를 구성하는 함수
    return DiaryPageFrame(
      // 다른 메인 탭 화면들과 동일한 우측 인덱스(다이어리/소식/결산/설정)
      // - 공연 전 화면은 특정 탭에 속하지 않으므로 active: null
      sideTabs: buildDiarySideTabs(context, active: null),
      child: Padding(
        // 왼쪽은 바인더 링(구멍) 영역과 겹치지 않도록 여백을 더 줌
        padding: const EdgeInsets.fromLTRB(32, 15, 15, 15),
        child: ConcertBeforePageContents(
          concertTitle: concertTitle,
          // 스크린 버전에서는 "닫기 힌트"가 UX와 안 맞을 수 있어 숨깁니다.
          showCloseHint: false,
        ),
      ),
    );
  }
}
