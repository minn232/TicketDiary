import 'package:flutter/material.dart';

import 'paper_style.dart';
import 'responsive_text.dart';

/// [백엔드 수정] 비스듬히 찍힌 공연 D-day 잉크 도장(소식 카드 포스터·상세 공연 기간 타일).
/// 공연 당일·임박(7일 이내)은 빨간 잉크, 그 외는 갈색 잉크.
class DDayStamp extends StatelessWidget {
  final String label;

  /// 글자 크기(sp 기준)
  final double fontSize;

  const DDayStamp({super.key, required this.label, this.fontSize = 11});

  @override
  Widget build(BuildContext context) {
    final days = label.startsWith('D-')
        ? int.tryParse(label.substring(2))
        : null;
    final urgent = label == 'D-DAY' || (days != null && days <= 7);
    final color = urgent ? PaperColors.stamp : PaperColors.ink;
    return Transform.rotate(
      angle: -0.14,
      child: Container(
        padding: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          // 포스터 위에서도 읽히게 종이 바탕을 살짝 깖
          color: PaperColors.card.withValues(alpha: .82),
          border: Border.all(color: color.withValues(alpha: .8), width: 1.4),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: .55), width: 0.8),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: context.sp(fontSize),
              fontWeight: FontWeight.w900,
              color: color.withValues(alpha: .9),
              letterSpacing: 0.6,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
