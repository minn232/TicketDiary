import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'paper_style.dart';

/// 서버 프로필과 분리된 기기 내 계정별 미리보기입니다.
class LocalProfileEditor extends StatefulWidget {
  const LocalProfileEditor({
    super.key,
    required this.userId,
    required this.nickname,
  });
  final String userId;
  final String nickname;
  @override
  State<LocalProfileEditor> createState() => _LocalProfileEditorState();
}

class _LocalProfileEditorState extends State<LocalProfileEditor> {
  String? _nickname;
  Uint8List? _photo;
  bool _ready = false;
  bool _busy = false;
  String get _key => 'profile_preview_${widget.userId}';
  String get _name => _nickname ?? widget.nickname;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        _nickname = data['name'] as String?;
        if (data['photo'] != null) {
          _photo = base64Decode(data['photo'] as String);
        }
      }
    } catch (_) {
      // 이전 미리보기가 손상되어도 다시 편집할 수 있습니다.
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _save(String? name, Uint8List? photo) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      _key,
      jsonEncode({
        'name': name,
        'photo': photo == null ? null : base64Encode(photo),
      }),
    )) {
      throw StateError('저장 실패');
    }
    if (mounted) {
      setState(() {
        _nickname = name;
        _photo = photo;
      });
    }
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: PaperColors.card,
        title: const Text('닉네임 설정'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '닉네임을 입력해주세요'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => TextButton(
              onPressed: value.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, value.text.trim()),
              child: const Text('저장'),
            ),
          ),
        ],
      ),
    );
    // 다이얼로그 퇴장 애니메이션 동안 컨트롤러가 사용됩니다.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (name == null || !mounted) return;
    await _run(() => _save(name, _photo));
  }

  Future<void> _editPhoto() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: PaperColors.card,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('앨범에서 선택'),
              onTap: () => Navigator.pop(context, 'pick'),
            ),
            if (_photo != null)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('기본 프로필로 변경'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    await _run(() async {
      if (action == 'remove') {
        await _save(_nickname, null);
      } else {
        final image = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 512,
          maxHeight: 512,
          imageQuality: 80,
        );
        if (image != null && mounted) {
          await _save(_nickname, await image.readAsBytes());
        }
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        showPaperSnackBar(context, '저장하지 못했어요. 사진 접근 권한을 확인하거나 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Semantics(
        button: true,
        label: '프로필 사진 변경',
        child: InkWell(
          onTap: _ready && !_busy ? _editPhoto : null,
          customBorder: const CircleBorder(),
          child: Stack(
            children: [
              if (_photo == null)
                ProfileAvatar(size: 88, name: _name)
              else
                ClipOval(
                  child: Image.memory(
                    _photo!,
                    width: 88,
                    height: 88,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        ProfileAvatar(size: 88, name: _name),
                  ),
                ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: const BoxDecoration(
                    color: PaperColors.tile,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.camera_alt_outlined,
                    size: 16,
                    color: PaperColors.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: '닉네임 수정',
            onPressed: _ready && !_busy ? _editName : null,
            icon: const Icon(
              Icons.edit_outlined,
              size: 19,
              color: PaperColors.muted,
            ),
          ),
          Flexible(
            child: Text(
              _name.isEmpty ? '카카오 계정' : _name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: PaperColors.ink,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
      const Text(
        '카카오 계정으로 로그인됨',
        style: TextStyle(color: PaperColors.muted, fontSize: 12),
      ),
      if (_busy) const LinearProgressIndicator(color: PaperColors.muted),
    ],
  );
}
