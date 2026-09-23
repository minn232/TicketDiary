import 'package:flutter/foundation.dart';

// [백엔드 수정]
// 티켓 page_layout(JSONB) 대응 모델. 백엔드 schemas/ticket.py의 PageLayout과 필드 일치.

/// 공연후 페이지 배치 아이템 종류.
enum PageLayoutItemType { poster, photo, text }

/// 사진 아이템 부가 정보. [w]/[h]는 EXIF 회전 적용 후 크기.
@immutable
class PageLayoutPhoto {
  final int w;
  final int h;
  final String? thumbUrl;

  /// EXIF 촬영 시각 원문(기기 현지 시각, 시간대 없음).
  final String? takenAt;
  final double? quality;

  const PageLayoutPhoto({
    required this.w,
    required this.h,
    this.thumbUrl,
    this.takenAt,
    this.quality,
  });

  double get aspect => w / h;

  factory PageLayoutPhoto.fromJson(Map<String, dynamic> json) =>
      PageLayoutPhoto(
        w: (json['w'] as num).toInt(),
        h: (json['h'] as num).toInt(),
        thumbUrl: json['thumb_url'] as String?,
        takenAt: json['taken_at'] as String?,
        quality: (json['quality'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
    'w': w,
    'h': h,
    if (thumbUrl != null) 'thumb_url': thumbUrl,
    if (takenAt != null) 'taken_at': takenAt,
    if (quality != null) 'quality': quality,
  };
}

/// 배치 아이템 하나. 캔버스 폭 = 1 정규화 좌표, [cx]/[cy]는 중심, [w]는 폭,
/// [rot]는 라디안. [ref]는 사진 URL 또는 자유메모 id.
@immutable
class PageLayoutItem {
  final String id;
  final PageLayoutItemType type;
  final String? ref;
  final String? text;
  final double cx;
  final double cy;
  final double w;
  final double rot;
  final int z;

  /// 유저가 직접 옮긴 아이템. 사진 추가로 재배치해도 그대로 둠.
  final bool pinned;
  final PageLayoutPhoto? photo;

  const PageLayoutItem({
    required this.id,
    required this.type,
    this.ref,
    this.text,
    required this.cx,
    required this.cy,
    required this.w,
    this.rot = 0,
    this.z = 0,
    this.pinned = false,
    this.photo,
  });

  factory PageLayoutItem.fromJson(Map<String, dynamic> json) => PageLayoutItem(
    id: json['id'] as String,
    type: PageLayoutItemType.values.byName(json['type'] as String),
    ref: json['ref'] as String?,
    text: json['text'] as String?,
    cx: (json['cx'] as num).toDouble(),
    cy: (json['cy'] as num).toDouble(),
    w: (json['w'] as num).toDouble(),
    rot: (json['rot'] as num?)?.toDouble() ?? 0,
    z: (json['z'] as num?)?.toInt() ?? 0,
    pinned: json['pinned'] as bool? ?? false,
    photo: json['photo'] == null
        ? null
        : PageLayoutPhoto.fromJson(json['photo'] as Map<String, dynamic>),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    if (ref != null) 'ref': ref,
    if (text != null) 'text': text,
    'cx': cx,
    'cy': cy,
    'w': w,
    'rot': rot,
    'z': z,
    'pinned': pinned,
    if (photo != null) 'photo': photo!.toJson(),
  };

  PageLayoutItem copyWith({
    double? cx,
    double? cy,
    double? w,
    double? rot,
    int? z,
    bool? pinned,
    String? text,
  }) => PageLayoutItem(
    id: id,
    type: type,
    ref: ref,
    text: text ?? this.text,
    cx: cx ?? this.cx,
    cy: cy ?? this.cy,
    w: w ?? this.w,
    rot: rot ?? this.rot,
    z: z ?? this.z,
    pinned: pinned ?? this.pinned,
    photo: photo,
  );
}

/// 공연후 페이지 배치 전체. [canvasAspect]는 생성 당시 캔버스 높이/폭.
@immutable
class PageLayout {
  final int version;
  final double canvasAspect;
  final List<PageLayoutItem> items;

  const PageLayout({
    this.version = 1,
    required this.canvasAspect,
    required this.items,
  });

  /// 형식이 깨진 값이면 null (배치 없이 새로 자동 배치하도록).
  static PageLayout? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    try {
      return PageLayout(
        version: (json['version'] as num?)?.toInt() ?? 1,
        canvasAspect: (json['canvas_aspect'] as num).toDouble(),
        items: [
          for (final item in json['items'] as List<dynamic>)
            PageLayoutItem.fromJson(item as Map<String, dynamic>),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'canvas_aspect': canvasAspect,
    'items': [for (final item in items) item.toJson()],
  };

  Iterable<PageLayoutItem> get photos =>
      items.where((i) => i.type == PageLayoutItemType.photo);
}
