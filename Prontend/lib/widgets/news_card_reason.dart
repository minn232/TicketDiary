import 'package:flutter/material.dart';
import 'dart:ui' show PointerDeviceKind;
import '../models/news_model.dart';
import '../models/artist_model.dart';
import 'paper_style.dart';

/// 카드 왼쪽 위 테두리: 아티스트 프로필을 공연 찜 문구보다 우선합니다.
class NewsCardReason extends StatelessWidget {
  const NewsCardReason({super.key, required this.data});
  final NewsModel data;

  @override
  Widget build(BuildContext context) {
    final artists = data.matchedArtists.isNotEmpty
        ? data.matchedArtists
        : data.isFavoritedConcert
        ? <ArtistModel>[]
        : [ArtistModel(name: data.artist, profileImageUrl: '')];
    if (artists.isEmpty) {
      return const Text(
        '찜한 공연',
        textAlign: TextAlign.left,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: PaperColors.muted,
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
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
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
                            color: PaperColors.muted.withValues(alpha: .35),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: a.profileImageUrl.trim().isEmpty
                            ? _fallback(a.name)
                            : Image.network(
                                a.profileImageUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => _fallback(a.name),
                              ),
                      ),
                    ),
                ],
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
