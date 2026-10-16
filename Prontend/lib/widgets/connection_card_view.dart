import 'package:flutter/material.dart';

import '../models/connection.dart';
import 'app_network_image.dart';
import 'responsive_text.dart';

// [백엔드 수정]
// 연결 카드 2장(우리 사이 - 취향·궁합·함께한 기록 / 다음에 같이) 스와이프.
class ConnectionCardView extends StatefulWidget {
  final ConnectionCard card;

  const ConnectionCardView({super.key, required this.card});

  @override
  State<ConnectionCardView> createState() => _ConnectionCardViewState();
}

class _ConnectionCardViewState extends State<ConnectionCardView> {
  final PageController _controller = PageController(viewportFraction: 0.9);
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final pages = <Widget Function(bool wide)>[
      (wide) => _UsPage(card: card, wide: wide),
      (wide) => _NextPage(card: card, wide: wide),
    ];
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _controller,
            itemCount: pages.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.rs(6),
                vertical: context.rs(12),
              ),
              child: _CardSheet(builder: pages[i]),
            ),
          ),
        ),
        if (pages.length > 1)
          Padding(
            padding: EdgeInsets.only(bottom: context.rs(14)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < pages.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(
                        alpha: i == _page ? 0.6 : 0.2,
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CardSheet extends StatelessWidget {
  // wide면 두 칸 배치 - 태블릿 가로처럼 카드가 낮고 넓을 때
  final Widget Function(bool wide) builder;

  const _CardSheet({required this.builder});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, box) {
          final pad = context.rs(18);
          final wide =
              box.maxWidth > 560 && box.maxWidth > box.maxHeight * 1.15;
          // 스크롤 없이 한 화면에 - 그래도 넘치면 넘치는 만큼만 전체를 축소
          return Padding(
            padding: EdgeInsets.all(pad),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: box.maxWidth - pad * 2,
                child: builder(wide),
              ),
            ),
          );
        },
      ),
    );
  }
}

// 공연 날짜는 한국 날짜를 UTC 자정으로 저장하므로 UTC 기준 연월일로 읽음
DateTime _kstDay(DateTime d) {
  final utc = d.toUtc();
  return DateTime(utc.year, utc.month, utc.day);
}

String _dayLabel(DateTime d) {
  final k = _kstDay(d);
  return '${k.year}.${k.month.toString().padLeft(2, '0')}.${k.day.toString().padLeft(2, '0')}';
}

String _dDay(DateTime d) {
  final now = DateTime.now();
  final diff = _kstDay(
    d,
  ).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (diff == 0) return 'D-DAY';
  return diff > 0 ? 'D-$diff' : 'D+${-diff}';
}

String? _ticketingLabel(DateTime? t) {
  if (t == null) return null;
  final local = t.toLocal();
  if (local.isBefore(DateTime.now())) return null;
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '티켓 오픈 ${local.month}/${local.day} $hh:$mm';
}

class _SectionTitle extends StatelessWidget {
  final String text;
  // 제목 아래 작은 설명 (예: 추천 근거)
  final String? caption;

  const _SectionTitle(this.text, {this.caption});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.rs(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: context.sp(13),
              fontWeight: FontWeight.w900,
              color: Colors.black54,
            ),
          ),
          if (caption != null)
            Text(
              caption!,
              style: TextStyle(fontSize: context.sp(11), color: Colors.black38),
            ),
        ],
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  final String? url;
  final double width;
  final double height;

  const _Poster({required this.url, required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: width,
      height: height,
      color: Colors.black.withValues(alpha: 0.06),
      child: Icon(
        Icons.music_note_rounded,
        color: Colors.black.withValues(alpha: 0.25),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: url == null
          ? placeholder
          : AppNetworkImage(
              url!,
              width: width,
              height: height,
              placeholderBuilder: (_) => placeholder,
              errorBuilder: (_) => placeholder,
            ),
    );
  }
}

/// 1장 "우리 사이" - 취향·궁합·공통 아티스트 + 함께한 기록, 넓은 화면에서는 두 칸.
/// 처음 열 때 살짝 커지며 나타남.
class _UsPage extends StatelessWidget {
  final ConnectionCard card;
  final bool wide;

  const _UsPage({required this.card, required this.wide});

  // 다른 날 본 공연은 이만큼만 보여주고 나머지는 "외 N개"
  static const _maxOtherDays = 2;

  List<Widget> _header(BuildContext context) {
    final compat = card.compatibility;
    final compatLine = compat == null
        ? null
        : compat.topSharedGenre != null
        ? '둘 다 ${compat.topSharedGenre} 공연을 즐겨 봐요'
        : compat.sharedArtistCount > 0
        ? '좋아하는 아티스트 ${compat.sharedArtistCount}명이 겹쳐요'
        : null;
    return [
      SizedBox(
        width: double.infinity,
        child: Text(
          '${card.peer.displayName}님과 나',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: context.sp(18),
            fontWeight: FontWeight.w900,
            color: Colors.black87,
          ),
        ),
      ),
      if (card.myTaste != null || card.peerTaste != null) ...[
        SizedBox(height: context.rs(14)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _TasteColumn(who: '나', taste: card.myTaste),
            ),
            SizedBox(width: context.rs(8)),
            Expanded(
              child: _TasteColumn(
                who: card.peer.displayName,
                taste: card.peerTaste,
              ),
            ),
          ],
        ),
      ],
      if (compat != null) ...[
        SizedBox(height: context.rs(14)),
        SizedBox(
          width: double.infinity,
          child: Text(
            '취향 궁합 ${compat.score}%',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(14.5),
              fontWeight: FontWeight.w900,
              color: const Color(0xFF8B5E3C),
            ),
          ),
        ),
        SizedBox(height: context.rs(5)),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: compat.score / 100,
            minHeight: 6,
            color: const Color(0xFF8B5E3C),
            backgroundColor: Colors.black.withValues(alpha: 0.06),
          ),
        ),
        if (compatLine != null) ...[
          SizedBox(height: context.rs(6)),
          SizedBox(
            width: double.infinity,
            child: Text(
              compatLine,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: context.sp(12), color: Colors.black54),
            ),
          ),
        ],
      ],
    ];
  }

  List<Widget> _together(BuildContext context) {
    if (card.togetherConcerts.isEmpty) return const [];
    final posterWidth = context.rs(84);
    return [
      _SectionTitle('같이 간 공연 ${card.togetherConcerts.length}회'),
      // 개수가 많아도 높이는 그대로 - 가로로 넘김
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in card.togetherConcerts)
              Padding(
                padding: EdgeInsets.only(right: context.rs(8)),
                child: SizedBox(
                  width: posterWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Poster(
                        url: c.posterUrl,
                        width: posterWidth,
                        height: context.rs(116),
                      ),
                      SizedBox(height: context.rs(3)),
                      Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.sp(10.5),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        _dayLabel(c.day),
                        style: TextStyle(
                          fontSize: context.sp(9.5),
                          color: Colors.black45,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      SizedBox(height: context.rs(14)),
    ];
  }

  List<Widget> _songs(BuildContext context) {
    if (card.sharedSongCount == 0) return const [];
    return [
      _SectionTitle('둘 다 라이브로 들은 곡 ${card.sharedSongCount}곡'),
      for (final song in card.sharedSongs)
        Padding(
          padding: EdgeInsets.only(bottom: context.rs(4)),
          child: Row(
            children: [
              Icon(
                Icons.graphic_eq_rounded,
                size: context.rs(15),
                color: const Color(0xFF8B5E3C),
              ),
              SizedBox(width: context.rs(8)),
              Expanded(
                child: Text(
                  song.artist == null
                      ? song.name
                      : '${song.name} - ${song.artist}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.sp(12.5),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${song.times}번',
                style: TextStyle(
                  fontSize: context.sp(10.5),
                  color: Colors.black45,
                ),
              ),
            ],
          ),
        ),
      SizedBox(height: context.rs(10)),
    ];
  }

  List<Widget> _commonArtists(BuildContext context) {
    if (card.commonArtists.isEmpty) return const [];
    return [
      const _SectionTitle('둘 다 좋아하는 아티스트'),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final artist in card.commonArtists)
            Chip(
              label: Text(artist, style: TextStyle(fontSize: context.sp(11.5))),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: const Color(0xFFF4F1E1),
              side: BorderSide.none,
            ),
        ],
      ),
      SizedBox(height: context.rs(12)),
    ];
  }

  List<Widget> _otherDays(BuildContext context) {
    final others = card.sameConcertOtherDays;
    if (others.isEmpty) return const [];
    final style = TextStyle(
      fontSize: context.sp(11.5),
      color: Colors.black54,
      height: 1.35,
    );
    return [
      for (final other in others.take(_maxOtherDays))
        Padding(
          padding: EdgeInsets.only(bottom: context.rs(4)),
          child: Text(
            '${other.concert.name}을 서로 다른 날 봤어요 (나 ${_dayLabel(other.myDate)}, '
            '${card.peer.displayName} ${_dayLabel(other.peerDate)})',
            style: style,
          ),
        ),
      if (others.length > _maxOtherDays)
        Text(
          '외 ${others.length - _maxOtherDays}개 공연도 서로 다른 날 봤어요',
          style: style,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final empty = !card.hasHistory && card.commonArtists.isEmpty;
    final emptyText = SizedBox(
      width: double.infinity,
      child: Text(
        '아직 겹치는 기록이 없어요\n같이 공연 보러 가볼까요?',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: context.sp(13.5),
          color: Colors.black54,
          height: 1.4,
        ),
      ),
    );
    final records = [
      ..._together(context),
      ..._songs(context),
      if (!wide) ..._commonArtists(context),
      ..._otherDays(context),
    ];
    final Widget content;
    if (wide && !empty) {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ..._header(context),
                SizedBox(height: context.rs(18)),
                ..._commonArtists(context),
              ],
            ),
          ),
          SizedBox(width: context.rs(24)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: records,
            ),
          ),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ..._header(context),
          SizedBox(height: context.rs(18)),
          if (empty) emptyText else ...records,
        ],
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
      ),
      child: content,
    );
  }
}

/// "우리 사이" 장의 한 사람 취향 - 이름 아래 "영미권 록/밴드" 같은 요약 한 줄.
class _TasteColumn extends StatelessWidget {
  final String who;
  final Taste? taste;

  const _TasteColumn({required this.who, required this.taste});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rs(10),
        vertical: context.rs(10),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F1E1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            who,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: context.sp(11.5), color: Colors.black54),
          ),
          SizedBox(height: context.rs(4)),
          Text(
            taste?.label ?? '아직 몰라요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.sp(13.5),
              fontWeight: FontWeight.w800,
              color: taste == null ? Colors.black38 : Colors.black87,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConcertRow extends StatelessWidget {
  final CardConcert concert;
  final String? caption;

  const _ConcertRow({required this.concert, this.caption});

  @override
  Widget build(BuildContext context) {
    final ticketing = _ticketingLabel(concert.ticketingDate);
    return Padding(
      padding: EdgeInsets.only(bottom: context.rs(8)),
      child: Row(
        children: [
          _Poster(
            url: concert.posterUrl,
            width: context.rs(44),
            height: context.rs(60),
          ),
          SizedBox(width: context.rs(10)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  concert.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.sp(13),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  [_dayLabel(concert.day), ?caption, ?ticketing].join(' | '),
                  style: TextStyle(
                    fontSize: context.sp(11),
                    color: Colors.black45,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _dDay(concert.day),
            style: TextStyle(
              fontSize: context.sp(13),
              fontWeight: FontWeight.w900,
              color: const Color(0xFFE0455E),
            ),
          ),
        ],
      ),
    );
  }
}

/// "각자의 다음 공연"에서 공연이 없거나 비공개일 때 - 공연 줄과 같은 높이의 빈 자리.
class _EmptyNextRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _EmptyNextRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.rs(8)),
      child: Row(
        children: [
          Container(
            width: context.rs(44),
            height: context.rs(60),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
            ),
            child: Icon(icon, size: context.rs(20), color: Colors.black26),
          ),
          SizedBox(width: context.rs(10)),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: context.sp(12.5),
                color: Colors.black45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 2장 "다음에 같이" - 넓은 화면에서는 다음 공연 / 관심 / 추천을 칸으로 나눔.
class _NextPage extends StatelessWidget {
  final ConnectionCard card;
  final bool wide;

  const _NextPage({required this.card, required this.wide});

  static String _statusLabel(String status) => status == 'ticket' ? '예매' : '찜';

  @override
  Widget build(BuildContext context) {
    final peer = card.peer.displayName;
    final next = <Widget>[
      if (card.togetherNext != null) ...[
        const _SectionTitle('같이 가는 다음 공연'),
        _ConcertRow(concert: card.togetherNext!),
      ] else ...[
        // 한쪽이 없어도 "없어요"로 자리를 둠
        const _SectionTitle('각자의 다음 공연'),
        if (card.myNext != null)
          _ConcertRow(concert: card.myNext!, caption: '나')
        else
          const _EmptyNextRow(
            icon: Icons.event_busy_rounded,
            text: '나는 아직 예정된 공연이 없어요',
          ),
        if (card.peerNext != null)
          _ConcertRow(concert: card.peerNext!, caption: peer)
        else if (card.peerNextHidden)
          _EmptyNextRow(
            icon: Icons.lock_outline_rounded,
            text: '$peer님의 다음 공연은 비공개예요',
          )
        else
          _EmptyNextRow(
            icon: Icons.event_busy_rounded,
            text: '$peer님은 아직 예정된 공연이 없어요',
          ),
      ],
    ];
    // 관심 공연과 추천 둘 다 표시, 관심 공연이 있으면 추천은 2개까지
    final genre = card.compatibility?.topSharedGenre;
    // 추천 근거 - 제목 아래 작은 글씨
    final suggestionReason = switch (card.suggestionBasis) {
      'genre' when genre != null => '둘 다 좋아하는 $genre 공연이에요',
      'mixed' when genre != null => '둘 다 좋아하는 아티스트와 $genre 공연이에요',
      _ => '둘 다 좋아하는 아티스트의 공연이에요',
    };
    final suggestions = card.suggestions.take(
      card.bothInterested.isEmpty ? 3 : 2,
    );
    final interested = <Widget>[
      if (card.bothInterested.isNotEmpty) ...[
        const _SectionTitle('둘 다 찜하거나 예매한 공연'),
        for (final item in card.bothInterested)
          _ConcertRow(
            concert: item.concert,
            caption:
                '나 ${_statusLabel(item.myStatus)}, $peer ${_statusLabel(item.peerStatus)}',
          ),
      ],
    ];
    final suggested = <Widget>[
      if (suggestions.isNotEmpty) ...[
        _SectionTitle('같이 가볼 만한 공연', caption: suggestionReason),
        for (final c in suggestions) _ConcertRow(concert: c),
      ],
    ];
    final more = [
      ...interested,
      if (interested.isNotEmpty && suggested.isNotEmpty)
        SizedBox(height: context.rs(6)),
      ...suggested,
    ];
    final title = Text(
      '다음에 같이',
      style: TextStyle(
        fontSize: context.sp(18),
        fontWeight: FontWeight.w900,
        color: Colors.black87,
      ),
    );
    if (wide && more.isNotEmpty) {
      // 관심 공연과 추천이 둘 다 있으면 세 칸(다음 공연 / 관심 / 추천), 아니면 두 칸
      final columns = interested.isNotEmpty && suggested.isNotEmpty
          ? [next, interested, suggested]
          : [next, more];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          SizedBox(height: context.rs(14)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, column) in columns.indexed) ...[
                if (i > 0) SizedBox(width: context.rs(20)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: column,
                  ),
                ),
              ],
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title,
        SizedBox(height: context.rs(14)),
        ...next,
        if (more.isNotEmpty) SizedBox(height: context.rs(6)),
        ...more,
      ],
    );
  }
}
