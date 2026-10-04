import 'package:flutter/material.dart';

import '../models/setlist.dart';
import 'app_network_image.dart';

// [백엔드 수정] 공연별 아티스트 연결 수정 시트 신규. ArtistAnchorSheet와 같은 톤.
const Color _paperColor = Color(0xFFF4F1E1);
const Color _ink = Color(0xFF463C2E);
const Color _accent = Color(0xFF8B5E3C);

const Map<String, String> _countryNames = {
  'KR': '한국',
  'JP': '일본',
  'US': '미국',
  'GB': '영국',
  'CN': '중국',
  'TW': '대만',
  'CA': '캐나다',
  'AU': '호주',
  'DE': '독일',
  'FR': '프랑스',
};

const Map<String, String> _typeNames = {
  'Person': '솔로',
  'Group': '그룹',
  'Orchestra': '오케스트라',
  'Choir': '합창단',
};

/// 이 공연의 [artist]가 누구인지 고르는 바텀시트. 후보를 고르거나 "아티스트가
/// 아니에요"를 누르면 [onPick] 후 닫힘. "목록에 없어요"면 true를 돌려주고 닫혀서
/// 호출부가 곡 제목 검색(ArtistAnchorSheet)으로 넘어감.
class ArtistIdentitySheet extends StatefulWidget {
  final String artist;
  final Future<IdentityCandidatesResponse> Function() onLoad;
  final Future<void> Function(IdentityCandidate? candidate) onPick;
  // false면 "목록에 없어요"(곡 제목 검색) 숨김 - 실제 셋리처럼 대표곡과 무관할 때.
  final bool allowSongSearch;

  const ArtistIdentitySheet({
    super.key,
    required this.artist,
    required this.onLoad,
    required this.onPick,
    this.allowSongSearch = true,
  });

  /// [onPick]의 인자가 null이면 "연결할 아티스트 없음".
  static Future<bool> show(
    BuildContext context, {
    required String artist,
    required Future<IdentityCandidatesResponse> Function() onLoad,
    required Future<void> Function(IdentityCandidate? candidate) onPick,
    bool allowSongSearch = true,
  }) async {
    final searchBySong = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _paperColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => ArtistIdentitySheet(
        artist: artist,
        onLoad: onLoad,
        onPick: onPick,
        allowSongSearch: allowSongSearch,
      ),
    );
    return searchBySong ?? false;
  }

  @override
  State<ArtistIdentitySheet> createState() => _ArtistIdentitySheetState();
}

class _ArtistIdentitySheetState extends State<ArtistIdentitySheet> {
  IdentityCandidatesResponse? _data;
  bool _loading = true;
  bool _picking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.onLoad();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _data = const IdentityCandidatesResponse();
        _loading = false;
        _error = '후보를 불러오지 못했어요.';
      });
    }
  }

  Future<void> _pick(IdentityCandidate? candidate) async {
    if (_picking) return;
    // 지금 연결된 걸 다시 고르면 바꿀 게 없음.
    final unchanged = candidate == null
        ? _data?.noArtist == true
        : candidate.isCurrent;
    if (unchanged) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      await widget.onPick(candidate);
      if (mounted) Navigator.of(context).pop(false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _error = '바꾸지 못했어요. 잠시 후 다시 시도해주세요.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
                '이 공연의 ${widget.artist}는 누구인가요?',
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
                '고른 아티스트로 이 공연의 셋리를 다시 찾아요.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: _ink.withValues(alpha: 0.6),
                ),
              ),
            ),
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
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _accent,
                          ),
                          if (_picking) ...[
                            const SizedBox(height: 12),
                            Text(
                              '셋리를 다시 찾는 중이에요',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: _ink.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  : _buildCandidates(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCandidates() {
    final data = _data ?? const IdentityCandidatesResponse();
    // 현재 연결된 아티스트를 맨 위로.
    final candidates = [
      ...data.candidates.where((c) => c.isCurrent),
      ...data.candidates.where((c) => !c.isCurrent),
    ];
    return ListView(
      children: [
        for (final candidate in candidates)
          ListTile(
            onTap: () => _pick(candidate),
            leading: _Photo(url: candidate.imageUrl),
            title: Text(
              candidate.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, color: _ink),
            ),
            subtitle: _describe(candidate).isEmpty && candidate.topSongs.isEmpty
                ? null
                : _Subtitle(candidate: candidate),
            trailing: candidate.isCurrent ? const _CurrentBadge() : null,
          ),
        if (data.candidates.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                '같은 이름의 아티스트를 찾지 못했어요.',
                style: TextStyle(color: _ink.withValues(alpha: 0.5)),
              ),
            ),
          ),
        if (widget.allowSongSearch)
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              '목록에 없어요 · 노래 제목으로 찾기',
              style: TextStyle(color: _accent, fontWeight: FontWeight.w700),
            ),
          ),
        TextButton(
          onPressed: () => _pick(null),
          child: Text(
            data.noArtist ? '아티스트가 아니에요 (지금 설정)' : '아티스트가 아니에요',
            style: TextStyle(
              color: _ink.withValues(alpha: 0.6),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// 동명이인 구분용 한 줄 - "한국 · 솔로 · 2015년~ · 설명".
String _describe(IdentityCandidate c) {
  return [
    if (c.country != null) _countryNames[c.country] ?? c.country!,
    if (c.type != null && _typeNames[c.type] != null) _typeNames[c.type]!,
    if (c.beginYear != null) '${c.beginYear}년~',
    if (c.disambiguation != null && c.disambiguation!.isNotEmpty)
      c.disambiguation!,
  ].join(' · ');
}

/// 설명 줄 + 곡 줄("♪ 곡1 · 곡2").
class _Subtitle extends StatelessWidget {
  final IdentityCandidate candidate;

  const _Subtitle({required this.candidate});

  @override
  Widget build(BuildContext context) {
    final description = _describe(candidate);
    final songs = candidate.topSongs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (description.isNotEmpty)
          Text(
            description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _ink.withValues(alpha: 0.6)),
          ),
        if (songs.isNotEmpty)
          Text(
            '♪ ${songs.join(' · ')}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _accent, fontSize: 12.5),
          ),
      ],
    );
  }
}

class _CurrentBadge extends StatelessWidget {
  const _CurrentBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: _accent),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '현재 아티스트',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: _accent,
        ),
      ),
    );
  }
}

class _Photo extends StatelessWidget {
  final String? url;

  const _Photo({this.url});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: url != null
          ? AppNetworkImage(
              url!,
              width: 44,
              height: 44,
              errorBuilder: (_) => const _PhotoPlaceholder(),
            )
          : const _PhotoPlaceholder(),
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      color: _ink.withValues(alpha: 0.08),
      child: Icon(Icons.person, color: _ink.withValues(alpha: 0.4)),
    );
  }
}
