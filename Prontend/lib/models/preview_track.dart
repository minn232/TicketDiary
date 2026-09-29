import 'package:flutter/foundation.dart';

/// 미리듣기 곡 한 곡. 백엔드 `PreviewTrack`과 대응.
@immutable
class PreviewTrack {
  final String trackName;
  final String artistName;
  final String previewUrl;
  final String? trackViewUrl;

  const PreviewTrack({
    required this.trackName,
    required this.artistName,
    required this.previewUrl,
    this.trackViewUrl,
  });

  factory PreviewTrack.fromJson(Map<String, dynamic> json) {
    return PreviewTrack(
      trackName: json['track_name'] as String,
      artistName: json['artist_name'] as String,
      previewUrl: json['preview_url'] as String,
      trackViewUrl: json['track_view_url'] as String?,
    );
  }
}

/// `GET /tickets/{ticketId}/preview-tracks` 응답.
@immutable
class PreviewTracksResponse {
  final String? source;
  final List<PreviewTrack> tracks;

  const PreviewTracksResponse({this.source, this.tracks = const []});

  factory PreviewTracksResponse.fromJson(Map<String, dynamic> json) {
    return PreviewTracksResponse(
      source: json['source'] as String?,
      tracks: (json['tracks'] as List<dynamic>? ?? const [])
          .map((e) => PreviewTrack.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
