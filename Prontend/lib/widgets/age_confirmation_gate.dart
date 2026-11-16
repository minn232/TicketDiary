import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'paper_style.dart';

/// 확인 전에는 앱의 Navigator와 초기 데이터 로딩을 시작하지 않습니다.
class AgeConfirmationGate extends StatefulWidget {
  const AgeConfirmationGate({super.key, required this.builder});

  static const preferenceKey = 'age_over_14_confirmed';
  final WidgetBuilder builder;

  @override
  State<AgeConfirmationGate> createState() => _AgeConfirmationGateState();
}

class _AgeConfirmationGateState extends State<AgeConfirmationGate> {
  bool _loading = true;
  bool _accepted = false;
  bool _declined = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _accepted = prefs.getBool(AgeConfirmationGate.preferenceKey) == true;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _accept() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setBool(
        AgeConfirmationGate.preferenceKey,
        true,
      );
      if (!saved) throw StateError('연령 확인 저장 실패');
      if (mounted) setState(() => _accepted = true);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '확인 결과를 저장하지 못했어요. 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_accepted) return widget.builder(context);
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: PaperColors.card,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: _loading
                    ? const CircularProgressIndicator(color: PaperColors.ink)
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.local_activity_outlined,
                            size: 48,
                            color: PaperColors.ink,
                          ),
                          const SizedBox(height: 24),
                          Text(
                            _declined ? '만 14세 이상만 이용할 수 있어요' : '만 14세 이상입니까?',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: PaperColors.ink,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _declined
                                ? '만 14세 미만은 티켓다이어리를 이용할 수 없어요.'
                                : '티켓다이어리는 만 14세 이상만 이용할 수 있어요.\n시작하기 전에 연령을 확인해주세요.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: PaperColors.muted,
                              height: 1.6,
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 16),
                            Text(_error!, textAlign: TextAlign.center),
                          ],
                          const SizedBox(height: 28),
                          if (_declined)
                            PaperButton(
                              label: '다시 확인하기',
                              style: PaperButtonStyle.quiet,
                              onTap: () => setState(() => _declined = false),
                            )
                          else
                            Wrap(
                              spacing: 16,
                              runSpacing: 12,
                              alignment: WrapAlignment.center,
                              children: [
                                PaperButton(
                                  label: '아니요',
                                  style: PaperButtonStyle.outline,
                                  onTap: _saving
                                      ? null
                                      : () => setState(() => _declined = true),
                                ),
                                PaperButton(
                                  label: _saving ? '저장 중…' : '예',
                                  onTap: _saving ? null : _accept,
                                ),
                              ],
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
