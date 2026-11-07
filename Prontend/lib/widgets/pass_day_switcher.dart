import 'package:flutter/material.dart';

import '../models/ticket_pass.dart';
import 'paper_style.dart';

// [백엔드 수정] 2일권/3일권 공연 전/후 페이지에서 다른 관람일로 넘어가는 날짜 탭 신규.

/// 묶음 티켓의 관람일 목록과 지금 보고 있는 날.
@immutable
class PassDayTabs {
  const PassDayTabs({required this.days, required this.selected});

  final List<DateTime> days;
  final int selected;
}

/// 페이지 위 가장자리에 붙는 종이 인덱스 탭. 지금 날은 페이지와 같은 종이색으로 이어 붙고,
/// 다른 날은 한 톤 어둡고 낮게 둠.
class PassDaySwitcher extends StatelessWidget {
  const PassDaySwitcher({
    super.key,
    required this.tabs,
    required this.onSelect,
    required this.pageColor,
  });

  static const double _selectedHeight = 34;
  static const double _otherHeight = 28;

  final PassDayTabs tabs;
  final ValueChanged<int> onSelect;

  /// 페이지 종이색 - 지금 날 탭이 페이지와 한 장처럼 보이게 같은 색을 씀.
  final Color pageColor;

  @override
  Widget build(BuildContext context) {
    final otherColor = Color.lerp(pageColor, PaperColors.muted, 0.16)!;
    final edge = Colors.black.withValues(alpha: 0.10);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < tabs.days.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: i == tabs.selected ? null : () => onSelect(i),
              child: Container(
                height: i == tabs.selected ? _selectedHeight : _otherHeight,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == tabs.selected ? pageColor : otherColor,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(8),
                  ),
                  border: Border(
                    top: BorderSide(color: edge, width: 1.5),
                    left: BorderSide(color: edge, width: 1.5),
                    right: BorderSide(color: edge, width: 1.5),
                  ),
                ),
                child: Text.rich(
                  TextSpan(
                    text: passDateLabel(tabs.days[i]),
                    children: [
                      TextSpan(
                        text: ' ${koreanWeekdays[tabs.days[i].weekday - 1]}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: i == tabs.selected
                        ? PaperColors.ink
                        : PaperColors.ink.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
