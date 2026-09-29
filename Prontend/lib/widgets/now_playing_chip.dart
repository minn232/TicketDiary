import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/preview_track.dart';
import '../services/ticket_preview_player.dart';

/// 미리듣기 재생 표시. ♪ 아이콘이 곡 전환 때 제목만, 탭하면 음소거/다음 곡 버튼까지 펼침.
class NowPlayingChip extends StatefulWidget {
  const NowPlayingChip({super.key});

  @override
  State<NowPlayingChip> createState() => _NowPlayingChipState();
}

class _NowPlayingChipState extends State<NowPlayingChip> {
  static const _collapseAfter = Duration(seconds: 4);
  static const _titleShownFor = Duration(seconds: 3);
  // 첫 곡은 아이콘이 먼저 나온 뒤 펼침
  static const _firstExpandDelay = Duration(milliseconds: 350);
  // 접힌/펼친 높이 동일
  static const _height = 36.0;

  // _controls: 버튼까지 펼침, 아니면 제목만
  bool _expanded = false;
  bool _controls = false;
  // 마지막으로 표시한 곡
  PreviewTrack? _track;
  Timer? _collapseTimer;
  Timer? _firstExpandTimer;

  @override
  void initState() {
    super.initState();
    _track = TicketPreviewPlayer.instance.current;
    TicketPreviewPlayer.instance.addListener(_onPlayerChanged);
  }

  @override
  void dispose() {
    TicketPreviewPlayer.instance.removeListener(_onPlayerChanged);
    _collapseTimer?.cancel();
    _firstExpandTimer?.cancel();
    super.dispose();
  }

  // 새 곡이 시작되면 제목만 잠깐 보여줌
  void _onPlayerChanged() {
    final track = TicketPreviewPlayer.instance.current;
    if (track == null || track == _track) return;
    final isFirst = _track == null;
    setState(() => _track = track);
    if (_controls) return;
    if (isFirst) {
      _firstExpandTimer?.cancel();
      _firstExpandTimer = Timer(_firstExpandDelay, () {
        if (mounted && !_controls) _setExpanded(true, controls: false);
      });
    } else {
      _setExpanded(true, controls: false);
    }
  }

  void _setExpanded(bool value, {required bool controls}) {
    _collapseTimer?.cancel();
    setState(() {
      _expanded = value;
      _controls = value && controls;
    });
    if (value) {
      _collapseTimer = Timer(controls ? _collapseAfter : _titleShownFor, () {
        if (mounted) setState(() => _expanded = _controls = false);
      });
    }
  }

  Future<void> _openTrackPage(String? url) async {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 못 열어도 무시
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = TicketPreviewPlayer.instance;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final track = _track;
        final visible = player.current != null && track != null;
        // 첫 등장도 애니메이션이 되도록 트리 유지
        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: Material(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(_height / 2),
              clipBehavior: Clip.antiAlias,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerRight,
                child: _expanded && track != null
                    ? _buildExpanded(player, track)
                    : InkWell(
                        onTap: () => _setExpanded(true, controls: true),
                        child: const SizedBox(
                          width: _height,
                          height: _height,
                          child: Icon(
                            Icons.music_note,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildExpanded(TicketPreviewPlayer player, PreviewTrack track) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width - 32,
        minHeight: _height,
        maxHeight: _height,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openTrackPage(track.trackViewUrl),
              child: Padding(
                padding: EdgeInsets.only(left: 14, right: _controls ? 2 : 14),
                child: Text(
                  '♪ ${track.trackName} · ${track.artistName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          if (_controls) ...[
            _iconButton(
              player.muted ? Icons.volume_off : Icons.volume_up,
              () => player.toggleMute(),
            ),
            _iconButton(Icons.skip_next, () => player.playAnother()),
          ],
        ],
      ),
    );
  }

  Widget _iconButton(IconData icon, VoidCallback action) {
    return IconButton(
      onPressed: () {
        action();
        _setExpanded(true, controls: true);
      },
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(
        width: _height,
        height: _height,
      ),
      iconSize: 19,
      color: Colors.white,
      icon: Icon(icon),
    );
  }
}
