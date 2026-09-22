import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ticket-local text override; untouched sections retain their live content.
class ConcertAfterEditableSection extends StatefulWidget {
  final String storageKey;
  final String title;
  final bool editMode;
  final Future<String> Function() loadOriginal;
  final Widget child;

  const ConcertAfterEditableSection({
    super.key,
    required this.storageKey,
    required this.title,
    required this.editMode,
    required this.loadOriginal,
    required this.child,
  });

  @override
  State<ConcertAfterEditableSection> createState() =>
      _ConcertAfterEditableSectionState();
}

class _ConcertAfterEditableSectionState
    extends State<ConcertAfterEditableSection> {
  static final Map<String, String?> _savedTextCache = {};

  String? _text;
  late bool _ready = _savedTextCache.containsKey(widget.storageKey);
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    if (_ready) {
      _text = _savedTextCache[widget.storageKey];
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(widget.storageKey);
      if (!mounted) return;
      if (saved != null) _savedTextCache[widget.storageKey] = saved;
      setState(() {
        _text = saved;
        _ready = true;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('저장된 내용을 불러오지 못했어요.')));
      }
    }
  }

  Future<void> _edit() async {
    if (!widget.editMode || !_ready || _opening) return;
    setState(() => _opening = true);
    try {
      final original = _text ?? await widget.loadOriginal();
      if (!mounted || !widget.editMode) return;
      final saved = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SectionEditor(
          title: widget.title,
          initialText: original,
          storageKey: widget.storageKey,
        ),
      );
      if (mounted && saved != null) setState(() => _text = saved);
      if (saved != null) _savedTextCache[widget.storageKey] = saved;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('내용을 불러오지 못했어요. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (!_ready || _text == null)
        widget.child
      else if (_text!.isNotEmpty)
        Text(
          _text!,
          style: const TextStyle(
            color: Color(0xFF463C2E),
            fontSize: 13,
            height: 1.5,
          ),
        ),
      if (widget.editMode)
        TextButton.icon(
          onPressed: _ready && !_opening ? _edit : null,
          icon: const Icon(Icons.edit_outlined, size: 14),
          label: Text(_opening ? '불러오는 중' : '편집'),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF463C2E),
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
        ),
    ],
  );
}

class _SectionEditor extends StatefulWidget {
  final String title;
  final String initialText;
  final String storageKey;

  const _SectionEditor({
    required this.title,
    required this.initialText,
    required this.storageKey,
  });

  @override
  State<_SectionEditor> createState() => _SectionEditorState();
}

class _SectionEditorState extends State<_SectionEditor> {
  late final _controller = TextEditingController(text: widget.initialText);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = _controller.text;
      if (!await prefs.setString(widget.storageKey, text)) {
        throw StateError('Could not save section');
      }
      if (mounted) Navigator.of(context).pop(text);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '저장하지 못했어요. 다시 시도해 주세요.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      backgroundColor: const Color(0xFFF4F1E1),
      title: Text('${widget.title} 편집'),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _controller,
          enabled: !_saving,
          autofocus: true,
          minLines: 5,
          maxLines: 12,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            hintText: '내용을 자유롭게 추가하거나 수정해 주세요.',
            helperText: '내용을 모두 지우고 저장하면 빈 항목으로 남아요.',
            helperMaxLines: 2,
            errorText: _error,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => _controller.clear(),
          child: const Text('내용 지우기'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '저장 중' : '저장'),
        ),
      ],
    ),
  );
}
