import 'package:flutter/material.dart';

import 'pressable_scale.dart';
import 'responsive_text.dart';

/// 다이어리 화면의 "티켓 추가" 영역에서 사용되는
/// 카메라/갤러리 옵션 버튼(아이콘 + 라벨).
class AddTicketOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const AddTicketOption({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      pressScale: 0.97,
      tapScale: 1.05,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              // 고정 40이라 폰(배율 작음)에서 카드 대비 너무 커 보였음 - rs로 맞춤
              width: context.rs(30),
              height: context.rs(30),
              // 접힌 "티켓 추가" 버튼의 + 원과 같은 갈색 원으로 맞춤
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF5A4033),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(icon, color: Colors.white, size: context.rs(17)),
            ),
            SizedBox(height: context.rs(5)),
            Text(
              label,
              style: TextStyle(
                fontSize: context.sp(11.5),
                fontWeight: FontWeight.w900,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
