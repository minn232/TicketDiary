import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import 'paper_style.dart';
import 'responsive_text.dart';

/// 계정 프로필(게스트·카카오 공통). 닉네임은 서버에 저장하고, 사진은 아직
/// 기기 안에만 계정별로 저장합니다.
class LocalProfileEditor extends StatefulWidget {
  const LocalProfileEditor({
    super.key,
    required this.userId,
    required this.nickname,
    this.isGuest = false,
  });
  final String userId;
  final String nickname;

  /// [백엔드 수정] 게스트도 같은 편집기를 쓰고 문구와 느낌표 도장만 다름.
  final bool isGuest;
  @override
  State<LocalProfileEditor> createState() => _LocalProfileEditorState();
}

class _LocalProfileEditorState extends State<LocalProfileEditor> {
  Uint8List? _photo;
  bool _ready = false;
  bool _busy = false;
  String get _key => 'profile_preview_${widget.userId}';
  // [백엔드 수정] 닉네임은 기기 저장값 대신 서버 값만 씀.
  String get _name => widget.nickname;

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
        if (data['photo'] != null) {
          _photo = base64Decode(data['photo'] as String);
        }
      }
    } catch (_) {
      // 이전 미리보기가 손상되어도 다시 편집할 수 있습니다.
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _savePhoto(Uint8List? photo) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      _key,
      jsonEncode({'photo': photo == null ? null : base64Encode(photo)}),
    )) {
      throw StateError('저장 실패');
    }
    if (mounted) setState(() => _photo = photo);
  }

  // [백엔드 수정] 종이 톤 입력창으로 바꾸고 저장은 창 안에서 서버에 바로 함.
  Future<void> _editName() => showNicknameDialog(context, initial: _name);

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
                title: const Text('기본 사진으로 되돌리기'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    await _run(() async {
      if (action == 'remove') {
        await _savePhoto(null);
      } else {
        final image = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 512,
          maxHeight: 512,
          imageQuality: 80,
        );
        if (image != null && mounted) {
          await _savePhoto(await image.readAsBytes());
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
        label: '프로필 사진 바꾸기',
        child: InkWell(
          onTap: _ready && !_busy ? _editPhoto : null,
          customBorder: const CircleBorder(),
          child: Stack(
            clipBehavior: Clip.none,
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
              if (widget.isGuest)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: PaperColors.stamp,
                      shape: BoxShape.circle,
                      border: Border.all(color: PaperColors.card, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '!',
                      style: TextStyle(
                        color: PaperColors.card,
                        fontSize: context.sp(14),
                        fontWeight: FontWeight.w900,
                        height: 1,
                      ),
                    ),
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
            tooltip: '닉네임 바꾸기',
            onPressed: _ready && !_busy ? _editName : null,
            icon: const Icon(
              Icons.edit_outlined,
              size: 19,
              color: PaperColors.muted,
            ),
          ),
          Flexible(
            child: Text(
              _name.isNotEmpty
                  ? _name
                  : (widget.isGuest ? '게스트로 쓰는 중' : '카카오 계정'),
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
      Text(
        widget.isGuest ? '아직 계정이 연결되지 않았어요' : '카카오 계정으로 로그인했어요',
        style: const TextStyle(color: PaperColors.muted, fontSize: 12),
      ),
      if (_busy) const LinearProgressIndicator(color: PaperColors.muted),
    ],
  );
}

/// 닉네임 입력 메모지를 띄웁니다(게스트·카카오 공통). 저장되면 알림 쪽지를 띄웁니다.
Future<void> showNicknameDialog(
  BuildContext context, {
  required String initial,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _NicknameDialog(initial: initial),
  );
  if (saved == true && context.mounted) {
    showPaperSnackBar(context, '닉네임을 바꿨어요.');
  }
}

/// 닉네임 입력 메모지. 저장 중·실패 안내를 창 안에서 보여주고, 저장되면
/// true로 닫힙니다.
class _NicknameDialog extends StatefulWidget {
  const _NicknameDialog({required this.initial});
  final String initial;

  @override
  State<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<_NicknameDialog> {
  static const _maxLength = 20;
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSave {
    final v = _controller.text.trim();
    return !_saving && v.isNotEmpty && v != widget.initial.trim();
  }

  Future<void> _submit() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AuthService.instance.updateNickname(_controller.text.trim());
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.statusCode == 422
            ? '쓸 수 없는 닉네임이에요. 다른 이름으로 해 주세요.'
            : '저장하지 못했어요. 잠시 후 다시 해 주세요.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '저장하지 못했어요. 인터넷 연결을 확인해 주세요.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 여백 배율은 showPaperDialog와 같게
    final k = 1 + (context.rs(1) - 1) * .5;
    final line = PaperColors.ink.withValues(alpha: .25);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: PaperNote(
        maxWidth: context.rs(300),
        angle: 0,
        padding: EdgeInsets.fromLTRB(22 * k, 26 * k, 22 * k, 16 * k),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '닉네임 바꾸기',
              style: TextStyle(
                fontSize: context.sp(16),
                fontWeight: FontWeight.w900,
                color: PaperColors.ink,
              ),
            ),
            SizedBox(height: 4 * k),
            Text(
              '셋리스트를 고치거나 공연 기록을 나눌 때\n다른 사람에게 보이는 이름이에요.',
              style: TextStyle(
                fontSize: context.sp(12),
                fontWeight: FontWeight.w600,
                color: PaperColors.muted,
                height: 1.5,
              ),
            ),
            SizedBox(height: 14 * k),
            // 상자 대신 메모지 밑줄 한 줄에 적는 느낌, 커서 손잡이도 갈색 잉크
            TextSelectionTheme(
              data: TextSelectionThemeData(
                cursorColor: PaperColors.ink,
                selectionHandleColor: PaperColors.ink,
                selectionColor: PaperColors.ink.withValues(alpha: .18),
              ),
              child: TextField(
                controller: _controller,
                autofocus: true,
                enabled: !_saving,
                maxLength: _maxLength,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _submit(),
                cursorColor: PaperColors.ink,
                style: TextStyle(
                  fontSize: context.sp(16),
                  fontWeight: FontWeight.w800,
                  color: PaperColors.ink,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '닉네임을 적어 주세요',
                  hintStyle: TextStyle(
                    fontSize: context.sp(15),
                    fontWeight: FontWeight.w600,
                    color: PaperColors.muted.withValues(alpha: .7),
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  counterStyle: TextStyle(
                    fontSize: context.sp(11),
                    color: PaperColors.muted,
                  ),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: line),
                  ),
                  disabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: line),
                  ),
                  focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: PaperColors.ink, width: 1.4),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(
                  fontSize: context.sp(12),
                  fontWeight: FontWeight.w700,
                  color: PaperColors.stamp,
                ),
              ),
            SizedBox(height: 14 * k),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8 * k,
                children: [
                  PaperButton(
                    label: '취소',
                    style: PaperButtonStyle.quiet,
                    onTap: _saving ? null : () => Navigator.pop(context, false),
                  ),
                  PaperButton(
                    label: _saving ? '저장 중…' : '저장',
                    onTap: _canSave ? _submit : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
