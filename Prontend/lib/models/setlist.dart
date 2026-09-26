import 'package:flutter/foundation.dart';

/// 곡 한 곡. 백엔드 `schemas/setlist.py`의 `SongEntry`와 대응.
@immutable
class SongEntry {
  final String name;
  final bool encore;

  // [백엔드 수정]
  /// 페스티벌처럼 아티스트가 여럿인 공연에서, 이 곡이 누구 소속인지.
  /// 단독 공연이면 null.
  final String? artist;

  // [백엔드 수정] source 추가 - 'representative'면 대표곡.
  final String? source;

  const SongEntry({
    required this.name,
    this.encore = false,
    this.artist,
    this.source,
  });

  bool get isRepresentative => source == 'representative';

  factory SongEntry.fromJson(Map<String, dynamic> json) {
    return SongEntry(
      name: json['name'] as String,
      encore: json['encore'] as bool? ?? false,
      artist: json['artist'] as String?,
      source: json['source'] as String?,
    );
  }

  // [백엔드 수정] 셋리스트 유저 수정(PATCH) 요청 body 직렬화용.
  Map<String, dynamic> toJson() => {
    'name': name,
    'encore': encore,
    'artist': artist,
    'source': source,
  };
}

/// `GET /concerts/{concertId}/setlist` 응답(실제 셋리스트).
/// 백엔드 `RealSetlistResponse`와 대응.
@immutable
class RealSetlistResponse {
  /// row가 없으면(Setlist.fm 매칭 실패 등) null.
  final String? id;
  final String concertId;
  final String? setlistfmId;
  final List<SongEntry> songs;
  final bool isUserEdited;
  final String? editedUserNickname;

  /// 콘서트에 등록된 아티스트 전원. [songs]에 없는 아티스트도 포함될 수 있음
  /// (placeholder 표시용).
  final List<String> artistNames;

  const RealSetlistResponse({
    this.id,
    required this.concertId,
    this.setlistfmId,
    required this.songs,
    required this.isUserEdited,
    this.editedUserNickname,
    this.artistNames = const [],
  });

  factory RealSetlistResponse.fromJson(Map<String, dynamic> json) {
    return RealSetlistResponse(
      id: json['id'] as String?,
      concertId: json['concert_id'] as String,
      setlistfmId: json['setlistfm_id'] as String?,
      songs: (json['songs'] as List<dynamic>? ?? const [])
          .map((e) => SongEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      isUserEdited: json['is_user_edited'] as bool,
      editedUserNickname: json['edited_user_nickname'] as String?,
      artistNames: (json['artist_names'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
    );
  }
}

/// `GET /concerts/{concertId}/setlist/pre` 응답(예상 셋리스트).
/// 백엔드 `PreSetlistResponse`와 대응.
@immutable
class PreSetlistResponse {
  // [백엔드 수정] 예상 셋리가 아직 없으면 null(빈 songs + artistNames만 옴).
  final String? id;
  final String concertId;
  final String? setlistfmId;
  final List<SongEntry> songs;
  final bool isUserEdited;
  final String? editedUserNickname;

  /// 콘서트에 등록된 아티스트(그 날짜 배정이 있으면 그 아티스트로 좁혀짐).
  /// [RealSetlistResponse.artistNames]와 동일 - 단독 공연에서 song.artist가
  /// 비어있는 곡을 음악앱 검색으로 연결할 때 폴백 아티스트로 씀.
  final List<String> artistNames;

  const PreSetlistResponse({
    required this.id,
    required this.concertId,
    this.setlistfmId,
    required this.songs,
    required this.isUserEdited,
    this.editedUserNickname,
    this.artistNames = const [],
  });

  factory PreSetlistResponse.fromJson(Map<String, dynamic> json) {
    return PreSetlistResponse(
      id: json['id'] as String?,
      concertId: json['concert_id'] as String,
      setlistfmId: json['setlistfm_id'] as String?,
      songs: (json['songs'] as List<dynamic>? ?? const [])
          .map((e) => SongEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      isUserEdited: json['is_user_edited'] as bool,
      editedUserNickname: json['edited_user_nickname'] as String?,
      artistNames: (json['artist_names'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
    );
  }
}

// [백엔드 수정] 예상 셋리 앵커 후보(공연 아티스트 이름으로 찾은 iTunes 아티스트) 신규.
/// `GET /tickets/{ticketId}/setlist/pre/artist-candidates` 응답 한 건.
/// 동명이인은 [genre]/[topSongs]로 구분.
@immutable
class ArtistCandidate {
  final String itunesArtistId;
  final String artistName;
  final String? genre;
  final List<String> topSongs;
  final String? artworkUrl;

  const ArtistCandidate({
    required this.itunesArtistId,
    required this.artistName,
    this.genre,
    this.topSongs = const [],
    this.artworkUrl,
  });

  factory ArtistCandidate.fromJson(Map<String, dynamic> json) {
    return ArtistCandidate(
      itunesArtistId: json['itunes_artist_id'] as String,
      artistName: json['artist_name'] as String,
      genre: json['genre'] as String?,
      topSongs: (json['top_songs'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
      artworkUrl: json['artwork_url'] as String?,
    );
  }
}

// [백엔드 수정] 예상 셋리 앵커 후보(iTunes 곡 검색 결과) 신규.
/// `GET /tickets/{ticketId}/setlist/pre/anchor-candidates` 응답 한 건.
/// 고르면 이 곡의 아티스트([itunesArtistId])로 확정됨.
@immutable
class ArtistAnchorCandidate {
  final String itunesArtistId;
  final String artistName;
  final String trackName;
  final String? albumName;
  final String? artworkUrl;

  const ArtistAnchorCandidate({
    required this.itunesArtistId,
    required this.artistName,
    required this.trackName,
    this.albumName,
    this.artworkUrl,
  });

  factory ArtistAnchorCandidate.fromJson(Map<String, dynamic> json) {
    return ArtistAnchorCandidate(
      itunesArtistId: json['itunes_artist_id'] as String,
      artistName: json['artist_name'] as String,
      trackName: json['track_name'] as String,
      albumName: json['album_name'] as String?,
      artworkUrl: json['artwork_url'] as String?,
    );
  }
}

// [백엔드 수정] 공연별 아티스트 연결 수정 후보 신규.
/// `GET /tickets/{ticketId}/artist-identity/candidates` 후보 한 건.
/// [canonicalId]가 없으면 MusicBrainz에만 있는 아티스트(고르면 [mbid]로 연결).
@immutable
class IdentityCandidate {
  final String? canonicalId;
  final String? mbid;
  final String name;
  final String? imageUrl;
  final String? country;
  final String? type;
  final String? disambiguation;
  final String? beginYear;
  // 알아보기용 곡 몇 개(인기순).
  final List<String> topSongs;
  final bool isCurrent;

  const IdentityCandidate({
    this.canonicalId,
    this.mbid,
    required this.name,
    this.imageUrl,
    this.country,
    this.type,
    this.disambiguation,
    this.beginYear,
    this.topSongs = const [],
    this.isCurrent = false,
  });

  factory IdentityCandidate.fromJson(Map<String, dynamic> json) {
    return IdentityCandidate(
      canonicalId: json['canonical_id'] as String?,
      mbid: json['mbid'] as String?,
      name: json['name'] as String,
      imageUrl: json['image_url'] as String?,
      country: json['country'] as String?,
      type: json['type'] as String?,
      disambiguation: json['disambiguation'] as String?,
      beginYear: json['begin_year']?.toString(),
      topSongs: (json['top_songs'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
      isCurrent: json['is_current'] as bool? ?? false,
    );
  }
}

/// 연결 수정 후보 응답 - [noArtist]면 지금 "연결할 아티스트 없음" 상태.
@immutable
class IdentityCandidatesResponse {
  final bool noArtist;
  final List<IdentityCandidate> candidates;

  const IdentityCandidatesResponse({
    this.noArtist = false,
    this.candidates = const [],
  });

  factory IdentityCandidatesResponse.fromJson(Map<String, dynamic> json) {
    return IdentityCandidatesResponse(
      noArtist: json['no_artist'] as bool? ?? false,
      candidates: (json['candidates'] as List<dynamic>? ?? const [])
          .map((e) => IdentityCandidate.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
