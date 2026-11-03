import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/kakao_login_controller.dart';
import 'paper_style.dart';

/// 선택을 완료하기 전에는 바깥 터치·드래그·시스템 뒤로가기로 닫히지 않습니다.
class FirstLaunchChoiceSheet extends StatefulWidget {
  const FirstLaunchChoiceSheet({
    super.key,
    required this.onKakaoLogin,
    required this.onComplete,
  });
  final Future<void> Function(BuildContext context) onKakaoLogin;
  final Future<void> Function() onComplete;

  static const preferenceKey = 'first_launch_account_choice';

  static Future<void> show(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: PaperColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => FirstLaunchChoiceSheet(
        onKakaoLogin: (context) => KakaoLoginController.instance.login(
          context: context,
          migrateFromGuest: false,
        ),
        onComplete: () async {
          final prefs = await SharedPreferences.getInstance();
          if (!await prefs.setString(preferenceKey, 'complete')) {
            throw StateError('선택 저장 실패');
          }
        },
      ),
    );
  }

  @override
  State<FirstLaunchChoiceSheet> createState() => _FirstLaunchChoiceSheetState();
}

class _FirstLaunchChoiceSheetState extends State<FirstLaunchChoiceSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _choose({required bool kakao}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (kakao) await widget.onKakaoLogin(context);
      await widget.onComplete();
      if (mounted) Navigator.of(context).pop();
    } on KakaoLoginCancelledException {
      // 취소하면 선택창을 유지합니다.
    } catch (_) {
      if (mounted) setState(() => _error = '진행하지 못했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '나의 공연 기록, 시작해볼까요?',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w800,
                color: PaperColors.ink,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '카카오 계정으로 로그인하거나\n게스트로 다이어리를 시작할 수 있어요.',
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: PaperColors.muted,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFEE500),
                foregroundColor: PaperColors.ink,
                minimumSize: const Size(0, 50),
              ),
              onPressed: _busy ? null : () => _choose(kakao: true),
              child: const Text('카카오로 로그인'),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: PaperColors.ink,
                minimumSize: const Size(0, 50),
                side: BorderSide(
                  color: PaperColors.muted.withValues(alpha: .4),
                ),
              ),
              onPressed: _busy ? null : () => _choose(kakao: false),
              child: const Text('게스트로 시작하기'),
            ),
            const SizedBox(height: 12),
            const Text(
              '게스트로 시작해도 나중에 설정에서 로그인할 수 있어요.',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: PaperColors.muted,
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: PaperColors.muted,
                    ),
                  ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: PaperColors.stamp),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
