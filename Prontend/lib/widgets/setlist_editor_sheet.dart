import 'package:flutter/material.dart';

import '../models/setlist.dart';

// [백엔드 수정]
// 셋리스트(실제/예상) 유저 수정 UI 신규. 백엔드 PATCH가 곡 배열을 통째로
// 교체하는 방식이라, 여기서도 전체 목록을 들고 있다가 저장 시 한 번에 넘김.
// 앱 전반의 크림지/갈색 잉크 톤(공연 전/후 페이지와 같은 계열)에 맞춤.
const Color _paperColor = Color(0xFFF4F1E1);
const Color _ink = Color(0xFF463C2E);
const Color _accent = Color(0xFF8B5E3C);

/// [showMenu]가 "취소(바깥 탭)"와 "미배정 선택"을 둘 다 null로 반환해서
/// 구분이 안 되는 문제 회피용 - 미배정을 고르면 이 값이 옵니다.
const Object _unassignedArtist = Object();

/// 셋리스트 곡을 추가/삭제/순서 변경하는 바텀시트. [onSave]가 예외 없이
/// 끝나면(성공) 시트가 닫힙니다.
///
/// [artistNames]가 2명 이상(페스티벌)이면 곡마다 아티스트 태그를 지정할 수
/// 있는 선택 칩이 함께 뜹니다(안 지정하면 "미배정"으로 저장 - 아티스트별로
/// 묶어 보여주는 화면에서 "아티스트 미상" 쪽으로 들어감). 1명 이하(단독
/// 공연)면 아티스트 UI 자체를 안 보여줍니다.
class SetlistEditorSheet extends StatefulWidget {
  final List<SongEntry> initialSongs;
  final List<String> artistNames;
  final Future<void> Function(List<SongEntry> songs) onSave;

  const SetlistEditorSheet({
    super.key,
    required this.initialSongs,
    this.artistNames = const [],
    required this.onSave,
  });

  static Future<void> show(
    BuildContext context, {
    required List<SongEntry> initialSongs,
    List<String> artistNames = const [],
    required Future<void> Function(List<SongEntry> songs) onSave,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _paperColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => SetlistEditorSheet(
        initialSongs: initialSongs,
        artistNames: artistNames,
        onSave: onSave,
      ),
    );
  }

  @override
  State<SetlistEditorSheet> createState() => _SetlistEditorSheetState();
}

class _SetlistEditorSheetState extends State<SetlistEditorSheet> {
  late List<SongEntry> _songs;
  late List<TextEditingController> _controllers;

  /// [_songs]/[_controllers]와 나란히 유지하는 안정적인 행 식별자 - 이름이
  /// 겹치는 곡이 있어도 ReorderableListView가 올바른 행을 추적하도록.
  late List<int> _ids;
  int _nextId = 0;

  final TextEditingController _newSongController = TextEditingController();
  String? _newSongArtist;
  bool _saving = false;
  String? _error;

  bool get _isFestival => widget.artistNames.length > 1;

  @override
  void initState() {
    super.initState();
    _songs = List.of(widget.initialSongs);
    _controllers = [
      for (final s in _songs) TextEditingController(text: s.name),
    ];
    _ids = [for (var i = 0; i < _songs.length; i++) _nextId++];
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    _newSongController.dispose();
    super.dispose();
  }

  void _addSong() {
    final name = _newSongController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _songs.add(SongEntry(name: name, artist: _newSongArtist));
      _controllers.add(TextEditingController(text: name));
      _ids.add(_nextId++);
      _newSongController.clear();
    });
  }

  void _removeAt(int index) {
    setState(() {
      _songs.removeAt(index);
      _controllers.removeAt(index).dispose();
      _ids.removeAt(index);
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      _songs.insert(newIndex, _songs.removeAt(oldIndex));
      _controllers.insert(newIndex, _controllers.removeAt(oldIndex));
      _ids.insert(newIndex, _ids.removeAt(oldIndex));
    });
  }

  Future<String?> _pickArtist(
    BuildContext context,
    Offset globalPosition,
    String? current,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final picked = await showMenu<Object?>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        CheckedPopupMenuItem<Object?>(
          value: _unassignedArtist,
          checked: current == null,
          child: const Text('미배정'),
        ),
        for (final artist in widget.artistNames)
          CheckedPopupMenuItem<Object?>(
            value: artist,
            checked: current == artist,
            child: Text(artist),
          ),
      ],
    );
    if (picked == null) return current; // 바깥을 눌러 취소.
    return picked == _unassignedArtist ? null : picked as String;
  }

  void _setSongArtist(int index, String? artist) {
    setState(() {
      _songs[index] = SongEntry(
        name: _songs[index].name,
        encore: _songs[index].encore,
        artist: artist,
      );
    });
  }

  Future<void> _handleSave() async {
    final finalSongs = [
      for (var i = 0; i < _songs.length; i++)
        SongEntry(
          name: _controllers[i].text.trim(),
          encore: _songs[i].encore,
          artist: _songs[i].artist,
        ),
    ]..removeWhere((s) => s.name.isEmpty);

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(finalSongs);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '저장하지 못했어요. 잠시 후 다시 시도해주세요.';
      });
    }
  }

  Widget _artistChip({
    required String? artist,
    required ValueChanged<String?> onPicked,
  }) {
    return Builder(
      builder: (context) => GestureDetector(
        onTapDown: (details) async {
          final picked = await _pickArtist(
            context,
            details.globalPosition,
            artist,
          );
          onPicked(picked);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: artist == null
                ? Colors.transparent
                : _accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _ink.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                artist ?? '미배정',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: artist == null ? _ink.withValues(alpha: 0.4) : _accent,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down,
                size: 16,
                color: _ink.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: _ink.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 10, 8),
                child: Row(
                  children: [
                    Icon(Icons.music_note, size: 18, color: _accent),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        '셋리스트 수정',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: _ink,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _saving ? null : _handleSave,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: _accent,
                        disabledBackgroundColor: _accent.withValues(alpha: 0.5),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('저장'),
                    ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
              const Divider(height: 16, color: Color(0x22463C2E)),
              Expanded(
                child: _songs.isEmpty
                    ? Center(
                        child: Text(
                          '곡이 없어요. 아래에서 추가해보세요.',
                          style: TextStyle(color: _ink.withValues(alpha: 0.5)),
                        ),
                      )
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: _songs.length,
                        onReorder: _reorder,
                        itemBuilder: (context, index) {
                          return Padding(
                            key: ValueKey(_ids[index]),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 3,
                            ),
                            child: Row(
                              children: [
                                ReorderableDragStartListener(
                                  index: index,
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Icon(
                                      Icons.drag_handle,
                                      color: _ink.withValues(alpha: 0.3),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 20,
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      color: _ink.withValues(alpha: 0.35),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: TextField(
                                    controller: _controllers[index],
                                    style: const TextStyle(
                                      color: _ink,
                                      fontSize: 14,
                                    ),
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      border: InputBorder.none,
                                    ),
                                  ),
                                ),
                                if (_isFestival) ...[
                                  _artistChip(
                                    artist: _songs[index].artist,
                                    onPicked: (a) => _setSongArtist(index, a),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                IconButton(
                                  icon: Icon(
                                    Icons.close,
                                    size: 18,
                                    color: _ink.withValues(alpha: 0.4),
                                  ),
                                  onPressed: () => _removeAt(index),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: _ink.withValues(alpha: 0.12)),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newSongController,
                        style: const TextStyle(color: _ink, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: '곡 추가',
                          hintStyle: TextStyle(
                            color: _ink.withValues(alpha: 0.35),
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.6),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: _ink.withValues(alpha: 0.2),
                            ),
                          ),
                        ),
                        onSubmitted: (_) => _addSong(),
                      ),
                    ),
                    if (_isFestival) ...[
                      const SizedBox(width: 6),
                      _artistChip(
                        artist: _newSongArtist,
                        onPicked: (a) => setState(() => _newSongArtist = a),
                      ),
                    ],
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _addSong,
                      style: IconButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
