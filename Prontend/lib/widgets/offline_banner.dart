import 'dart:async';

import 'package:flutter/material.dart';

import '../services/connectivity_status.dart';

// [백엔드 수정]
// 오프라인 배너 신규 - [ConnectivityStatus]가 오프라인이면 화면 위쪽에 표시.
class OfflineBanner extends StatefulWidget {
  /// 화면이 자체적으로 "지금 캐시를 보여주는 중"이라고 판단했으면 true로
  /// 넘깁니다 - 전역 신호가 먼저 풀려도 화면이 재확인할 때까지 배너를 유지.
  final bool forceVisible;

  const OfflineBanner({super.key, this.forceVisible = false});

  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

// [백엔드 수정]
// 계속 떠 있지 않고 몇 초만 보여준 뒤 페이드아웃 - isOffline/forceVisible이
// false->true로 새로 바뀔 때마다 다시 나타나고 타이머가 재시작됩니다.
class _OfflineBannerState extends State<OfflineBanner> {
  static const _visibleDuration = Duration(seconds: 3);
  static const _fadeDuration = Duration(milliseconds: 500);

  bool _visible = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    ConnectivityStatus.instance.isOffline.addListener(_onOfflineChanged);
    _syncVisibility();
  }

  @override
  void didUpdateWidget(covariant OfflineBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.forceVisible != oldWidget.forceVisible) _syncVisibility();
  }

  @override
  void dispose() {
    ConnectivityStatus.instance.isOffline.removeListener(_onOfflineChanged);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _onOfflineChanged() {
    if (mounted) _syncVisibility();
  }

  void _syncVisibility() {
    final shouldShow =
        ConnectivityStatus.instance.isOffline.value || widget.forceVisible;
    if (shouldShow && !_visible) {
      setState(() => _visible = true);
      _hideTimer?.cancel();
      _hideTimer = Timer(_visibleDuration, () {
        if (mounted) setState(() => _visible = false);
      });
    } else if (!shouldShow && _visible) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: SafeArea(
          bottom: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: _fadeDuration,
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
        ),
      ),
    );
  }
}
