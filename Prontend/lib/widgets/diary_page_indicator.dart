import 'package:flutter/material.dart';
import 'paper_style.dart';
import 'responsive_text.dart';

/// 액자 테두리 아래쪽에 그리는 "가로로 더 스크롤할 수 있어요" 화살표 힌트.
class DiaryPageIndicator extends StatelessWidget {
  final int page;
  final int pageCount;

  const DiaryPageIndicator({
    super.key,
    required this.page,
    required this.pageCount,
  });

  @override
  Widget build(BuildContext context) {
    final color = PaperColors.muted;
    // [백엔드 수정] 아래 여백 높이(_insets.bottom)는 고정인데 아이콘/글자는 화면 배율로
    // 커져서 세로모드에서 위아래가 잘렸음 - 넘칠 때만 여백 높이에 맞춰 축소.
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chevron_left,
              size: context.rs(15),
              color: color.withValues(alpha: page > 0 ? 1 : 0.3),
            ),
            SizedBox(width: context.rs(2)),
            Text(
              '${page + 1} / $pageCount',
              style: TextStyle(
                fontSize: context.sp(10),
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            SizedBox(width: context.rs(2)),
            Icon(
              Icons.chevron_right,
              size: context.rs(15),
              color: color.withValues(alpha: page < pageCount - 1 ? 1 : 0.3),
            ),
          ],
        ),
      ),
    );
  }
}
