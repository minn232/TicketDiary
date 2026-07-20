import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/kakao_login_debug_log.dart';

/// 카카오 로그인 화면을 인앱 웹뷰로 띄우고, 카카오가 콜백 URL로 이동을
/// 시도하는 순간을 가로채 인가 코드(`code`)만 뽑아 반환합니다.
///
/// 콜백 URL(`.../auth/kakao/callback`)은 실제로 응답하는 백엔드 API가
/// 아닙니다 — 카카오와 앱 사이의 "신호" 역할만 하고, 이 화면이 그 이동
/// 시도 자체를 막아서(`NavigationDecision.prevent`) 실제 요청이 나가지
/// 않게 합니다. 그래서 백엔드가 이 경로에 응답할 필요가 없습니다.
///
/// [Navigator.pop]으로 인가 코드(성공) 또는 null(취소/에러)을 반환합니다.
class KakaoLoginWebViewScreen extends StatefulWidget {
  final String loginUrl;

  const KakaoLoginWebViewScreen({super.key, required this.loginUrl});

  @override
  State<KakaoLoginWebViewScreen> createState() =>
      _KakaoLoginWebViewScreenState();
}

class _KakaoLoginWebViewScreenState extends State<KakaoLoginWebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _resultHandled = false;

  @override
  void initState() {
    super.initState();
    KakaoLoginDebugLog.add('[2] 웹뷰 loadRequest -> ${widget.loginUrl}');
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _handleNavigationRequest,
          onPageStarted: (url) {
            KakaoLoginDebugLog.add('[3] onPageStarted: $url');
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (url) {
            KakaoLoginDebugLog.add('[3] onPageFinished: $url');
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            KakaoLoginDebugLog.add(
              '[3] onWebResourceError: code=${error.errorCode}, '
              'desc=${error.description}, url=${error.url}',
            );
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.loginUrl));
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    final isCallback = uri != null && uri.path.endsWith('/auth/kakao/callback');
    KakaoLoginDebugLog.add(
      '[4] onNavigationRequest: ${request.url} '
      '(콜백 매칭=$isCallback, 이미처리=$_resultHandled)',
    );
    if (!isCallback) return NavigationDecision.navigate;

    // code는 1회용이라, 같은 콜백으로 두 번 이동하려 해도 한 번만 처리합니다.
    if (!_resultHandled) {
      _resultHandled = true;
      final code = uri.queryParameters['code'];
      final error = uri.queryParameters['error'];
      KakaoLoginDebugLog.add(
        '[4] 콜백 감지: redirect_uri(host+path)=${uri.origin}${uri.path}, '
        'code=${KakaoLoginDebugLog.mask(code)}, error=$error',
      );
      // 네비게이션 콜백 도중 pop하면 안 되므로, 다음 프레임으로 미룹니다.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(code);
      });
    } else {
      KakaoLoginDebugLog.add('[4] 이미 처리된 콜백이라 무시(중복 네비게이션 감지됨)');
    }
    return NavigationDecision.prevent;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('카카오 로그인'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
