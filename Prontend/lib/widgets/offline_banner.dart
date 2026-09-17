import 'package:flutter/material.dart';

import '../services/connectivity_status.dart';

// [백엔드 수정]
// 오프라인 배너 신규 - [ConnectivityStatus]가 오프라인이면 화면 위쪽에 표시,
// 서버가 다시 응답하면 자동으로 사라짐.
class OfflineBanner extends StatelessWidget {
  /// 화면이 자체적으로 "지금 캐시를 보여주는 중"이라고 판단했으면 true로
  /// 넘깁니다 - 전역 신호가 먼저 풀려도 화면이 재확인할 때까지 배너를 유지.
  final bool forceVisible;

  const OfflineBanner({super.key, this.forceVisible = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityStatus.instance.isOffline,
      builder: (context, isOffline, _) {
        if (!isOffline && !forceVisible) return const SizedBox.shrink();
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off, size: 14, color: Colors.white),
                    SizedBox(width: 6),
                    Text(
                      '오프라인 - 마지막으로 불러온 내용을 보여주고 있어요',
                      style: TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
