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

  const SongEntry({required this.name, this.encore = false, this.artist});

  factory SongEntry.fromJson(Map<String, dynamic> json) {
    return SongEntry(
      name: json['name'] as String,
      encore: json['encore'] as bool? ?? false,
      artist: json['artist'] as String?,
    );
  }
}

/// `GET /concerts/{concertId}/setlist` 응답(실제 셋리스트).
/// 백엔드 `RealSetlistResponse`와 대응.
@immutable
class RealSetlistResponse {
  /// row가 아직 없으면(Setlist.fm에서 못 찾음 등) null - 그래도 [artistNames]는
  /// 채워져 있을 수 있음.
  final String? id;
  final String concertId;
  final String? setlistfmId;
  final List<SongEntry> songs;
  final bool isUserEdited;
  final String? editedUserNickname;

  /// 콘서트에 등록된 아티스트 전원(페스티벌이면 여럿). [songs]에 없는 아티스트도
  /// 여기엔 포함될 수 있어서(Setlist.fm 매칭 실패), 프론트가 "아직 채워지지
  /// 않았어요" placeholder를 보여주는 데 씀.
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
  final String id;
  final String concertId;
  final String? setlistfmId;
  final List<SongEntry> songs;
  final bool isUserEdited;
  final String? editedUserNickname;

  const PreSetlistResponse({
    required this.id,
    required this.concertId,
    this.setlistfmId,
    required this.songs,
    required this.isUserEdited,
    this.editedUserNickname,
  });

  factory PreSetlistResponse.fromJson(Map<String, dynamic> json) {
    return PreSetlistResponse(
      id: json['id'] as String,
      concertId: json['concert_id'] as String,
      setlistfmId: json['setlistfm_id'] as String?,
      songs: (json['songs'] as List<dynamic>? ?? const [])
          .map((e) => SongEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      isUserEdited: json['is_user_edited'] as bool,
      editedUserNickname: json['edited_user_nickname'] as String?,
    );
  }
}
