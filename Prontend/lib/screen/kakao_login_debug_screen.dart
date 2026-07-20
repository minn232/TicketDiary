import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/kakao_login_debug_log.dart';

/// 카카오 로그인 흐름 진단용 임시 화면. 실기기에서 로그인을 한 번 시도한
/// 뒤 이 화면을 열면, 각 단계([0]~[5])에서 무슨 값이 오갔는지 확인할 수
/// 있습니다. 원인 파악 후 이 파일과 설정 화면의 진입점을 지우면 됩니다.
class KakaoLoginDebugScreen extends StatefulWidget {
  const KakaoLoginDebugScreen({super.key});

  @override
  State<KakaoLoginDebugScreen> createState() => _KakaoLoginDebugScreenState();
}

class _KakaoLoginDebugScreenState extends State<KakaoLoginDebugScreen> {
  @override
  Widget build(BuildContext context) {
    final entries = KakaoLoginDebugLog.entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('카카오 로그인 디버그 로그'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '전체 복사',
            onPressed: entries.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(
                      ClipboardData(text: entries.join('\n')),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('로그를 클립보드에 복사했어요.')),
                    );
                  },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '지우기',
            onPressed: () {
              setState(() => KakaoLoginDebugLog.clear());
            },
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '아직 로그가 없어요.\n"카카오로 로그인"을 한 번 시도한 뒤 다시 열어주세요.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 12),
              itemBuilder: (context, index) => SelectableText(
                entries[index],
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
    );
  }
}
