import 'package:flutter/material.dart';

import 'pressable_scale.dart';

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
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.22),
                  width: 1.4,
                ),
              ),
              child: Icon(
                icon,
                color: Colors.black.withValues(alpha: 0.78),
                size: 22,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
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

