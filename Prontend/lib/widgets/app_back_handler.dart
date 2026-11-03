import 'dart:async';
import 'package:flutter/material.dart';

/// 같은 라우트 안의 펼친 UI부터 닫습니다. 별도 팝업 라우트에는 전파하지 않습니다.
class AppBackHandler extends StatefulWidget {
  const AppBackHandler({
    super.key,
    required this.canHandle,
    required this.onBack,
    required this.child,
  });
  final bool Function() canHandle;
  final FutureOr<void> Function() onBack;
  final Widget child;
  static final _entries = <_AppBackHandlerState>[];
  static final _busy = <ModalRoute<dynamic>>{};

  static Future<bool> handle(BuildContext context) async {
    final route = ModalRoute.of(context);
    if (route == null) return false;
    if (_busy.contains(route)) return true;
    for (final entry in List.of(_entries.reversed)) {
      if (entry.mounted && entry.route == route && entry.widget.canHandle()) {
        _busy.add(route);
        try {
          await entry.widget.onBack();
        } finally {
          _busy.remove(route);
        }
        return true;
      }
    }
    return false;
  }

  @override
  State<AppBackHandler> createState() => _AppBackHandlerState();
}

class _AppBackHandlerState extends State<AppBackHandler> {
  ModalRoute<dynamic>? route;
  @override
  void initState() {
    super.initState();
    AppBackHandler._entries.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    AppBackHandler._entries.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 저장 중에는 닫지 않고, 저장하지 않은 입력은 버리기 전에 확인합니다.
class DiscardChangesGuard extends StatefulWidget {
  const DiscardChangesGuard({
    super.key,
    required this.isDirty,
    required this.isSaving,
    required this.child,
  });
  final bool Function() isDirty;
  final bool Function() isSaving;
  final Widget child;
  @override
  State<DiscardChangesGuard> createState() => _DiscardChangesGuardState();
}

class _DiscardChangesGuardState extends State<DiscardChangesGuard> {
  bool _asking = false;
  Future<void> _back() async {
    if (_asking || widget.isSaving()) return;
    _asking = true;
    try {
      final discard =
          !widget.isDirty() ||
          await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('수정을 취소할까요?'),
                  content: const Text('저장하지 않은 변경 내용이 사라집니다.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('계속 편집'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('버리고 닫기'),
                    ),
                  ],
                ),
              ) ==
              true;
      if (discard && mounted && !widget.isSaving()) Navigator.of(context).pop();
    } finally {
      _asking = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_back());
    },
    child: widget.child,
  );
}
