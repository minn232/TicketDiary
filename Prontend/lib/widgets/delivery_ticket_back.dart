import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 실제 티켓과 테스트 티켓이 공유하는 배송 전 뒷면.
class DeliveryTicketBack extends StatelessWidget {
  const DeliveryTicketBack({
    super.key,
    required this.date,
    required this.venue,
    required this.seat,
    required this.price,
    this.time = '00:00',
    this.delivery,
    this.onReceived,
  });
  final String date, venue, seat, price, time;

  // [백엔드 수정] 배송 예정일(공연 날짜와 구분해 오른쪽 빈 칸에 표시).
  final String? delivery;

  // [백엔드 수정] 배송일 전에 티켓을 먼저 받았을 때 공연 전으로 넘기는 버튼(null이면 숨김).
  final VoidCallback? onReceived;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 높이가 작아져도 두 열의 가로 영역은 축소하지 않습니다.
          final size = math.min(12.0, constraints.maxHeight / 8);
          Widget field(String label, String value) => Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: size * 3,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: size * .9,
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: size,
                      height: 1.1,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '공연 정보',
                    style: TextStyle(
                      fontSize: size,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                  const Spacer(),
                  if (onReceived != null)
                    GestureDetector(
                      key: const ValueKey('delivery-received'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onReceived,
                      child: Text(
                        '받았어요 ›',
                        style: TextStyle(
                          fontSize: size,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        key: const ValueKey('delivery-left'),
                        children: [
                          field('날짜', date),
                          field('시간', time),
                          field('공연장', venue),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        key: const ValueKey('delivery-right'),
                        children: [
                          field('좌석', seat),
                          field('가격', price),
                          if (delivery != null)
                            field('배송일', delivery!)
                          else
                            const Spacer(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
