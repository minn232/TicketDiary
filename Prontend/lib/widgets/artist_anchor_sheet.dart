import 'package:flutter/material.dart';

import '../models/setlist.dart';
import 'app_network_image.dart';

// [백엔드 수정] 예상 셋리 앵커(아티스트 확정) 시트 신규. SetlistEditorSheet와 같은 톤.
const Color _paperColor = Color(0xFFF4F1E1);
const Color _ink = Color(0xFF463C2E);
const Color _accent = Color(0xFF8B5E3C);

/// [artist] 후보 중 하나를 고르는 바텀시트. "여기 없어요"면 곡 제목 검색으로 넘어가고,
/// [onPick]이 성공하면 닫힘.
class ArtistAnchorSheet extends StatefulWidget {
  final String artist;
  final Future<List<ArtistCandidate>> Function() onSearchArtists;
  final Future<List<ArtistAnchorCandidate>> Function(String song) onSearchSongs;
  final Future<void> Function(String itunesArtistId) onPick;

  const ArtistAnchorSheet({
    super.key,
    required this.artist,
    required this.onSearchArtists,
    required this.onSearchSongs,
    required this.onPick,
  });

  static Future<void> show(
    BuildContext context, {
    required String artist,
    required Future<List<ArtistCandidate>> Function() onSearchArtists,
    required Future<List<ArtistAnchorCandidate>> Function(String song)
    onSearchSongs,
    required Future<void> Function(String itunesArtistId) onPick,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _paperColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => ArtistAnchorSheet(
        artist: artist,
        onSearchArtists: onSearchArtists,
        onSearchSongs: onSearchSongs,
        onPick: onPick,
      ),
    );
  }

  @override
  State<ArtistAnchorSheet> createState() => _ArtistAnchorSheetState();
}

class _ArtistAnchorSheetState extends State<ArtistAnchorSheet> {
  final TextEditingController _controller = TextEditingController();

  /// false면 아티스트 후보 단계, true면 곡 제목 검색 단계.
  bool _songMode = false;
  List<ArtistCandidate>? _artists;
  List<ArtistAnchorCandidate>? _songs;
  bool _loading = true;
  bool _picking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadArtists();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadArtists() async {
    try {
      final artists = await widget.onSearchArtists();
      if (!mounted) return;
      setState(() {
        _artists = artists;
        _loading = false;
        // 후보가 하나도 없으면 바로 곡 제목 검색으로.
        _songMode = artists.isEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _artists = const [];
        _loading = false;
        _songMode = true;
      });
    }
  }

  Future<void> _searchSongs() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _loading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final songs = await widget.onSearchSongs(query);
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '검색하지 못했어요. 잠시 후 다시 시도해주세요.';
      });
    }
  }

  Future<void> _pick(String itunesArtistId) async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      await widget.onPick(itunesArtistId);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _error = '대표곡을 불러오지 못했어요. 다른 후보로 다시 시도해주세요.';
      });
    }
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _ink.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 2),
                child: Text(
                  _songMode
                      ? '${widget.artist}의 노래를 하나 알려주세요'
                      : '어느 ${widget.artist}인가요?',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: _ink,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Text(
                  _songMode
                      ? '고른 곡의 아티스트로 대표곡을 채워요.'
                      : '고르면 그 아티스트의 대표곡으로 채워요.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: _ink.withValues(alpha: 0.6),
                  ),
                ),
              ),
              if (_songMode) _buildSongSearchField(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 4,
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
              const Divider(height: 16, color: Color(0x22463C2E)),
              Expanded(
                child: _loading || _picking
                    ? const Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _accent,
                        ),
                      )
                    : _songMode
                    ? _buildSongResults()
                    : _buildArtistResults(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSongSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _searchSongs(),
        style: const TextStyle(color: _ink),
        decoration: InputDecoration(
          hintText: '곡 제목',
          isDense: true,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          suffixIcon: IconButton(
            onPressed: _searchSongs,
            icon: const Icon(Icons.search, color: _accent),
          ),
        ),
      ),
    );
  }

  Widget _buildArtistResults() {
    final artists = _artists ?? const [];
    return ListView(
      children: [
        for (final candidate in artists)
          ListTile(
            onTap: () => _pick(candidate.itunesArtistId),
            leading: _Artwork(url: candidate.artworkUrl),
            title: Text(
              [
                candidate.artistName,
                if (candidate.genre != null) candidate.genre!,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, color: _ink),
            ),
            subtitle: Text(
              candidate.topSongs.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _ink.withValues(alpha: 0.6)),
            ),
          ),
        TextButton(
          onPressed: () => setState(() {
            _songMode = true;
            _error = null;
          }),
          child: const Text(
            '여기 없어요 · 곡 제목으로 찾기',
            style: TextStyle(color: _accent, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _buildSongResults() {
    final songs = _songs;
    if (songs == null) return const SizedBox.shrink();
    if (songs.isEmpty) {
      return Center(
        child: Text(
          '찾는 곡이 없어요. 다른 제목으로 검색해보세요.',
          style: TextStyle(color: _ink.withValues(alpha: 0.5)),
        ),
      );
    }
    return ListView.builder(
      itemCount: songs.length,
      itemBuilder: (context, index) {
        final candidate = songs[index];
        return ListTile(
          onTap: () => _pick(candidate.itunesArtistId),
          leading: _Artwork(url: candidate.artworkUrl),
          title: Text(
            candidate.trackName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, color: _ink),
          ),
          subtitle: Text(
            [
              candidate.artistName,
              if (candidate.albumName != null) candidate.albumName!,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _ink.withValues(alpha: 0.6)),
          ),
        );
      },
    );
  }
}

class _Artwork extends StatelessWidget {
  final String? url;

  const _Artwork({this.url});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: url != null
          ? AppNetworkImage(
              url!,
              width: 44,
              height: 44,
              errorBuilder: (_) => const _ArtworkPlaceholder(),
            )
          : const _ArtworkPlaceholder(),
    );
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      color: _ink.withValues(alpha: 0.08),
      child: Icon(Icons.music_note, color: _ink.withValues(alpha: 0.4)),
    );
  }
}
