import 'package:flutter/foundation.dart';

/// 곡 한 곡. 백엔드 `schemas/setlist.py`의 `SongEntry`와 대응.
@immutable
class SongEntry {
  final String name;
  final bool encore;

  const SongEntry({required this.name, this.encore = false});

  factory SongEntry.fromJson(Map<String, dynamic> json) {
    return SongEntry(
      name: json['name'] as String,
      encore: json['encore'] as bool? ?? false,
    );
  }
}

/// `GET /concerts/{concertId}/setlist` 응답(실제 셋리스트).
/// 백엔드 `RealSetlistResponse`와 대응.
@immutable
class RealSetlistResponse {
  final String id;
  final String concertId;
  final String? setlistfmId;
  final List<SongEntry> songs;
  final bool isUserEdited;
  final String? editedUserNickname;

  const RealSetlistResponse({
    required this.id,
    required this.concertId,
    this.setlistfmId,
    required this.songs,
    required this.isUserEdited,
    this.editedUserNickname,
  });

  factory RealSetlistResponse.fromJson(Map<String, dynamic> json) {
    return RealSetlistResponse(
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
