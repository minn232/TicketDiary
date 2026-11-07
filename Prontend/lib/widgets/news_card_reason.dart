import 'package:flutter/material.dart';
import 'dart:ui' show PointerDeviceKind;
import '../models/news_model.dart';
import '../models/artist_model.dart';
import 'paper_style.dart';

/// 카드 왼쪽 위 테두리: 아티스트 프로필을 공연 찜 문구보다 우선합니다.
class NewsCardReason extends StatefulWidget {
  const NewsCardReason({super.key, required this.data});
  final NewsModel data;

  @override
  State<NewsCardReason> createState() => _NewsCardReasonState();
}

class _NewsCardReasonState extends State<NewsCardReason>
    with SingleTickerProviderStateMixin {
  late final AnimationController _marquee;
  final _contentKey = GlobalKey();
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _marquee = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
  }

  @override
  void dispose() {
    _marquee.dispose();
    super.dispose();
  }

  void _measure() {
    final box = _contentKey.currentContext?.findRenderObject() as RenderBox?;
    final viewport = context.findRenderObject() as RenderBox?;
    if (box == null || viewport == null) return;
    final next = (box.size.width - viewport.size.width).clamp(
      0.0,
      double.infinity,
    );
    if ((next - _overflow).abs() < .5) return;
    _overflow = next;
    if (_overflow > 0) {
      _marquee.repeat(reverse: true);
    } else {
      _marquee.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final artists = widget.data.matchedArtists.isNotEmpty
        ? widget.data.matchedArtists
        : widget.data.isFavoritedConcert
        ? <ArtistModel>[]
        // [백엔드 수정] artist는 출연진 표시("A 외 N팀")라 매칭된 아티스트 이름을 씀.
        : [
            ArtistModel(
              name: widget.data.matchedArtist ?? widget.data.artist,
              profileImageUrl: '',
            ),
          ];
    if (artists.isEmpty) {
      return Semantics(
        label: '찜한 공연',
        child: const Align(
          alignment: Alignment.centerLeft,
          child: _FavoriteConcertMark(),
        ),
      );
    }
    final label = '찜한 아티스트: ${artists.map((a) => a.name).join(', ')}';
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: ExcludeSemantics(
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              scrollbars: false,
              dragDevices: {
                ...ScrollConfiguration.of(context).dragDevices,
                PointerDeviceKind.mouse,
              },
            ),
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _marquee,
                builder: (_, child) => Transform.translate(
                  offset: Offset(
                    -_overflow * Curves.easeInOut.transform(_marquee.value),
                    0,
                  ),
                  child: child,
                ),
                child: Builder(
                  builder: (_) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _measure(),
                    );
                    return OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: 0,
                      maxWidth: double.infinity,
                      child: Row(
                        key: _contentKey,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final a in artists)
                            Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Container(
                                key: ValueKey('news-artist-${a.name}'),
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: PaperColors.tile,
                                  border: Border.all(
                                    color: PaperColors.muted.withValues(
                                      alpha: .35,
                                    ),
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: a.profileImageUrl.trim().isEmpty
                                    ? _fallback(a.name)
                                    : Image.network(
                                        a.profileImageUrl,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) =>
                                            _fallback(a.name),
                                      ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const Icon(
        Icons.person_rounded,
        size: 15,
        color: PaperColors.muted,
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            trimmed.characters.first.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              height: 1,
              fontWeight: FontWeight.w900,
              color: PaperColors.ink.withValues(alpha: .55),
            ),
          ),
        ),
      ),
    );
  }
}

// [백엔드 수정] 찜한 공연 표시 - 이모지 ♥는 기기 컬러 이모지로 그려져 종이 톤과 안 맞아서
// 아티스트 프로필과 같은 동그라미 안에 평평한 하트로.
class _FavoriteConcertMark extends StatelessWidget {
  const _FavoriteConcertMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: PaperColors.tile,
        border: Border.all(color: PaperColors.muted.withValues(alpha: .35)),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.favorite,
        size: 11,
        color: Color.lerp(PaperColors.tapeRose, PaperColors.stamp, .3),
      ),
    );
  }
}
