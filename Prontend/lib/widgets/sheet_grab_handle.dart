import 'package:flutter/material.dart';

import 'responsive_text.dart';

/// [백엔드 수정] 아래에서 올라오는 패널(알림함/친구) 맨 위의 회색 손잡이 막대.
/// 끌어서 닫을 수 있다는 표시라, 실제 드래그는 이 막대를 포함한 제목줄 전체에서 받음.
class SheetGrabHandle extends StatelessWidget {
  const SheetGrabHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Center(
        child: Container(
          width: context.rs(40),
          height: 4,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }
}
