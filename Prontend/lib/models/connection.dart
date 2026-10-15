// [백엔드 수정]
// 폰 맞대기 연결(`/social/connections`, `/social/nearby`) 응답 모델.

DateTime? _date(dynamic raw) =>
    raw == null ? null : DateTime.parse(raw as String);

// 날짜만 있는 값("2026-09-12")은 공연 날짜와 같은 규칙(UTC 자정)으로 맞춤
DateTime _dateOnly(String raw) {
  final d = DateTime.parse(raw);
  return DateTime.utc(d.year, d.month, d.day);
}

List<T> _list<T>(dynamic raw, T Function(Map<String, dynamic>) parse) => [
  for (final item in (raw as List<dynamic>? ?? const []))
    parse((item as Map).cast<String, dynamic>()),
];

/// 연결 상대 프로필.
class ConnectionPeer {
  final String userId;
  final String? nickname;
  final String? profileImageUrl;

  const ConnectionPeer({
    required this.userId,
    this.nickname,
    this.profileImageUrl,
  });

  /// 닉네임 없는 게스트 계정은 "친구"로 표시.
  String get displayName =>
      (nickname?.trim().isNotEmpty ?? false) ? nickname!.trim() : '친구';

  factory ConnectionPeer.fromJson(Map<String, dynamic> json) => ConnectionPeer(
    userId: json['user_id'] as String,
    nickname: json['nickname'] as String?,
    profileImageUrl: json['profile_image_url'] as String?,
  );
}

/// 연결된 상대 한 명(연결 목록 항목).
class UserConnection {
  final String connectionId;
  final ConnectionPeer peer;
  final DateTime connectedAt;
  final DateTime? lastMetAt;

  const UserConnection({
    required this.connectionId,
    required this.peer,
    required this.connectedAt,
    this.lastMetAt,
  });

  factory UserConnection.fromJson(Map<String, dynamic> json) => UserConnection(
    connectionId: json['connection_id'] as String,
    peer: ConnectionPeer.fromJson(
      (json['peer'] as Map).cast<String, dynamic>(),
    ),
    connectedAt: DateTime.parse(json['connected_at'] as String),
    lastMetAt: _date(json['last_met_at']),
  );
}

/// 카드에 보여줄 공연 요약.
class CardConcert {
  final String id;
  final String name;
  final String? posterUrl;
  final String? venue;
  final DateTime startDate;
  final DateTime endDate;
  final DateTime? attendedDate;
  final DateTime? ticketingDate;

  const CardConcert({
    required this.id,
    required this.name,
    this.posterUrl,
    this.venue,
    required this.startDate,
    required this.endDate,
    this.attendedDate,
    this.ticketingDate,
  });

  /// 관람(예정)일을 알면 그 날, 모르면 공연 시작일.
  DateTime get day => attendedDate ?? startDate;

  factory CardConcert.fromJson(Map<String, dynamic> json) => CardConcert(
    id: json['id'] as String,
    name: json['name'] as String,
    posterUrl: json['poster_url'] as String?,
    venue: json['venue'] as String?,
    startDate: DateTime.parse(json['start_date'] as String),
    endDate: DateTime.parse(json['end_date'] as String),
    attendedDate: json['attended_date'] == null
        ? null
        : _dateOnly(json['attended_date'] as String),
    ticketingDate: _date(json['ticketing_date']),
  );
}

class Compatibility {
  final int score;
  final String? topSharedGenre;
  final int sharedArtistCount;

  const Compatibility({
    required this.score,
    this.topSharedGenre,
    required this.sharedArtistCount,
  });

  factory Compatibility.fromJson(Map<String, dynamic> json) => Compatibility(
    score: json['score'] as int,
    topSharedGenre: json['top_shared_genre'] as String?,
    sharedArtistCount: json['shared_artist_count'] as int,
  );
}

/// 한 사람의 취향 요약 - 아티스트 국적 큰 줄기 + 대표 장르 (예: "영미권 록/밴드").
class Taste {
  final List<String> origins;
  final bool originMixed;
  final List<String> genres;

  const Taste({
    required this.origins,
    required this.originMixed,
    required this.genres,
  });

  static const _originLabels = {
    'domestic': '국내',
    'japan': '일본',
    'anglo': '영미권',
    'other': '해외',
  };

  /// 장르가 없으면 "영미권 음악"처럼 국적만, 국적이 없으면 장르만.
  /// 국적 둘은 "국내와 일본"처럼 조사로 이음.
  String get label {
    final names = [for (final o in origins) _originLabels[o] ?? o];
    final origin = originMixed
        ? '여러 나라'
        : names.length == 2
        ? '${names[0]}${_hasBatchim(names[0]) ? '과' : '와'} ${names[1]}'
        : names.join(' ');
    final genre = genres.join(', ');
    if (origin.isEmpty) return genre;
    if (genre.isEmpty) return '$origin 음악';
    return '$origin $genre';
  }

  // 한글 마지막 글자에 받침이 있는지 (와/과 고르기)
  static bool _hasBatchim(String word) {
    final code = word.codeUnitAt(word.length - 1);
    return code >= 0xAC00 && code <= 0xD7A3 && (code - 0xAC00) % 28 != 0;
  }

  factory Taste.fromJson(Map<String, dynamic> json) => Taste(
    origins: [for (final o in json['origins'] as List<dynamic>) o as String],
    originMixed: json['origin_mixed'] as bool? ?? false,
    genres: [for (final g in json['genres'] as List<dynamic>) g as String],
  );
}

class SharedSong {
  final String name;
  final String? artist;
  final int times;

  const SharedSong({required this.name, this.artist, required this.times});

  factory SharedSong.fromJson(Map<String, dynamic> json) => SharedSong(
    name: json['name'] as String,
    artist: json['artist'] as String?,
    times: json['times'] as int,
  );
}

class SameConcertOtherDay {
  final CardConcert concert;
  final DateTime myDate;
  final DateTime peerDate;

  const SameConcertOtherDay({
    required this.concert,
    required this.myDate,
    required this.peerDate,
  });

  factory SameConcertOtherDay.fromJson(Map<String, dynamic> json) =>
      SameConcertOtherDay(
        concert: CardConcert.fromJson(
          (json['concert'] as Map).cast<String, dynamic>(),
        ),
        myDate: _dateOnly(json['my_date'] as String),
        peerDate: _dateOnly(json['peer_date'] as String),
      );
}

/// 둘 다 관심 있는 다가오는 공연 - 상태는 "ticket"(예매) 또는 "follow"(찜).
class InterestedConcert {
  final CardConcert concert;
  final String myStatus;
  final String peerStatus;

  const InterestedConcert({
    required this.concert,
    required this.myStatus,
    required this.peerStatus,
  });

  factory InterestedConcert.fromJson(Map<String, dynamic> json) =>
      InterestedConcert(
        concert: CardConcert.fromJson(
          (json['concert'] as Map).cast<String, dynamic>(),
        ),
        myStatus: json['my_status'] as String,
        peerStatus: json['peer_status'] as String,
      );
}

/// 연결 카드(우리 사이 - 취향·궁합·함께한 기록 / 다음에 같이).
class ConnectionCard {
  final ConnectionPeer peer;
  final DateTime connectedAt;
  final DateTime? lastMetAt;

  final int togetherCount;
  final String? latestTogetherPosterUrl;
  final Compatibility? compatibility;
  final List<String> commonArtists;
  final Taste? myTaste;
  final Taste? peerTaste;

  final List<CardConcert> togetherConcerts;
  final int sharedSongCount;
  final List<SharedSong> sharedSongs;
  final List<SameConcertOtherDay> sameConcertOtherDays;

  final CardConcert? myNext;
  final CardConcert? peerNext;
  final CardConcert? togetherNext;
  final bool peerNextHidden;
  final List<InterestedConcert> bothInterested;
  final List<CardConcert> suggestions;
  // 추천 근거 - "artist"(공통 아티스트 공연) / "genre"(둘 다 좋아하는 장르 공연) / "mixed"(둘 다)
  final String? suggestionBasis;

  const ConnectionCard({
    required this.peer,
    required this.connectedAt,
    this.lastMetAt,
    required this.togetherCount,
    this.latestTogetherPosterUrl,
    this.compatibility,
    required this.commonArtists,
    this.myTaste,
    this.peerTaste,
    required this.togetherConcerts,
    required this.sharedSongCount,
    required this.sharedSongs,
    required this.sameConcertOtherDays,
    this.myNext,
    this.peerNext,
    this.togetherNext,
    required this.peerNextHidden,
    required this.bothInterested,
    required this.suggestions,
    this.suggestionBasis,
  });

  bool get hasHistory =>
      togetherConcerts.isNotEmpty ||
      sharedSongCount > 0 ||
      sameConcertOtherDays.isNotEmpty;

  factory ConnectionCard.fromJson(Map<String, dynamic> json) {
    final us = (json['us'] as Map).cast<String, dynamic>();
    final history = (json['history'] as Map).cast<String, dynamic>();
    final next = (json['next'] as Map).cast<String, dynamic>();
    CardConcert? concert(dynamic raw) => raw == null
        ? null
        : CardConcert.fromJson((raw as Map).cast<String, dynamic>());
    Taste? taste(dynamic raw) => raw == null
        ? null
        : Taste.fromJson((raw as Map).cast<String, dynamic>());
    return ConnectionCard(
      peer: ConnectionPeer.fromJson(
        (json['peer'] as Map).cast<String, dynamic>(),
      ),
      connectedAt: DateTime.parse(json['connected_at'] as String),
      lastMetAt: _date(json['last_met_at']),
      togetherCount: us['together_count'] as int,
      latestTogetherPosterUrl: us['latest_together_poster_url'] as String?,
      compatibility: us['compatibility'] == null
          ? null
          : Compatibility.fromJson(
              (us['compatibility'] as Map).cast<String, dynamic>(),
            ),
      commonArtists: [
        for (final a in (us['common_artists'] as List<dynamic>? ?? const []))
          a as String,
      ],
      myTaste: taste(us['my_taste']),
      peerTaste: taste(us['peer_taste']),
      togetherConcerts: _list(
        history['together_concerts'],
        CardConcert.fromJson,
      ),
      sharedSongCount: history['shared_song_count'] as int,
      sharedSongs: _list(history['shared_songs'], SharedSong.fromJson),
      sameConcertOtherDays: _list(
        history['same_concert_other_days'],
        SameConcertOtherDay.fromJson,
      ),
      myNext: concert(next['my_next']),
      peerNext: concert(next['peer_next']),
      togetherNext: concert(next['together_next']),
      peerNextHidden: next['peer_next_hidden'] as bool? ?? false,
      bothInterested: _list(
        next['both_interested'],
        InterestedConcert.fromJson,
      ),
      suggestions: _list(next['suggestions'], CardConcert.fromJson),
      suggestionBasis: next['suggestion_basis'] as String?,
    );
  }
}

/// 맞댐 판정을 올린 결과 - waiting(상대 판정 전) / pending(확인 필요) / connected(이미 연결).
class SightingResult {
  final String status;
  final String? connectionId;
  final ConnectionPeer? peer;
  final bool confirmedByMe;

  /// 두 폰이 같은 순간에 상대 카드를 펼치는 서버 시각.
  final DateTime? revealAt;

  const SightingResult({
    required this.status,
    this.connectionId,
    this.peer,
    this.confirmedByMe = false,
    this.revealAt,
  });

  factory SightingResult.fromJson(Map<String, dynamic> json) => SightingResult(
    status: json['status'] as String,
    connectionId: json['connection_id'] as String?,
    peer: json['peer'] == null
        ? null
        : ConnectionPeer.fromJson(
            (json['peer'] as Map).cast<String, dynamic>(),
          ),
    confirmedByMe: json['confirmed_by_me'] as bool? ?? false,
    revealAt: json['reveal_at'] == null
        ? null
        : DateTime.parse(json['reveal_at'] as String),
  );
}

/// 연결 요청 확인 결과 - finishAt은 두 폰이 같은 순간에 연결 완료 애니메이션을 시작하는 서버 시각.
class ConfirmResult {
  final bool connected;
  final DateTime? finishAt;

  const ConfirmResult({required this.connected, this.finishAt});

  factory ConfirmResult.fromJson(Map<String, dynamic> json) => ConfirmResult(
    connected: json['status'] == 'connected',
    finishAt: json['finish_at'] == null
        ? null
        : DateTime.parse(json['finish_at'] as String),
  );
}

/// 확인 대기 중인 연결 요청.
class ConnectionRequest {
  final String connectionId;
  final ConnectionPeer peer;
  final DateTime requestedAt;
  final bool confirmedByMe;

  const ConnectionRequest({
    required this.connectionId,
    required this.peer,
    required this.requestedAt,
    required this.confirmedByMe,
  });

  factory ConnectionRequest.fromJson(Map<String, dynamic> json) =>
      ConnectionRequest(
        connectionId: json['connection_id'] as String,
        peer: ConnectionPeer.fromJson(
          (json['peer'] as Map).cast<String, dynamic>(),
        ),
        requestedAt: DateTime.parse(json['requested_at'] as String),
        confirmedByMe: json['confirmed_by_me'] as bool? ?? false,
      );
}
