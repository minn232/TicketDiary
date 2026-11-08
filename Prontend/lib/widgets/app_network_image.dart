import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// 네트워크 이미지 공통 위젯 - `Image.network`를 직접 쓰던 곳을 이걸로
/// 교체합니다.
///
/// - 모바일/데스크톱: [CachedNetworkImage]로 디스크 캐싱(재실행해도 다시
///   안 받음). 그 외 동작(디코드 해상도 등)은 기존 `Image.network`와 동일.
/// - 웹: KOPIS처럼 CORS 헤더가 없는 이미지 서버 대응이 필요해서, 기존
///   `Image.network`의 `webHtmlElementStrategy` 폴백(실패 시 `<img>` 태그로
///   렌더링)을 그대로 씀 - `CachedNetworkImage`엔 이 CORS 우회 기능이 없어서
///   웹만 예외로 둠(디스크 캐싱은 못 받지만 기존과 동일하게 동작).
///
/// [memCacheWidth]/[memCacheHeight]는 명시적으로 넘겼을 때만 적용됩니다(자동
/// 계산 안 함) - 렌더 박스 크기로 가로/세로를 각각 그대로 넘기면 원본
/// 이미지 비율과 안 맞을 때 디코드 단계에서 이미지가 찌그러질 수 있어서,
/// 꼭 필요한 곳에서만 원본 비율을 고려해 직접 계산해 넘기는 걸 권장합니다.
class AppNetworkImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final WidgetBuilder? placeholderBuilder;
  final WidgetBuilder? errorBuilder;

  /// true면 페이드 없이 바로 표시 (공유 이미지 캡처용).
  final bool instant;

  const AppNetworkImage(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.memCacheWidth,
    this.memCacheHeight,
    this.placeholderBuilder,
    this.errorBuilder,
    this.instant = false,
  });

  @override
  Widget build(BuildContext context) {
    final normalizedUrl = _normalizeUrl(url);
    if (kIsWeb) {
      // 웹은 기존 동작 그대로 유지(위 클래스 doc 참고).
      return Image.network(
        normalizedUrl,
        fit: fit,
        width: width,
        height: height,
        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
        loadingBuilder: placeholderBuilder == null
            ? null
            : (context, child, progress) =>
                  progress == null ? child : placeholderBuilder!(context),
        errorBuilder: errorBuilder == null
            ? null
            : (context, error, stackTrace) => errorBuilder!(context),
      );
    }

    return CachedNetworkImage(
      imageUrl: normalizedUrl,
      fit: fit,
      width: width,
      height: height,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      fadeInDuration: instant
          ? Duration.zero
          : const Duration(milliseconds: 500),
      fadeOutDuration: instant
          ? Duration.zero
          : const Duration(milliseconds: 1000),
      placeholder: placeholderBuilder == null
          ? null
          : (context, url) => placeholderBuilder!(context),
      errorWidget: errorBuilder == null
          ? null
          : (context, url, error) => errorBuilder!(context),
    );
  }

  /// [백엔드 수정] 화면에 그리기 전에 메모리에 미리 디코드해 둠 - 처음 열 때 자리표시·페이드 없이
  /// 바로 뜨게. memCacheWidth/Height 없이 쓰는 곳(포스터)과 같은 키라야 캐시가 맞음.
  /// 화면(context)과 무관하게 돌아서 스플래시가 닫힌 뒤 끝나도 됨.
  /// [decodeWidth]는 그 이미지를 그리는 쪽의 [memCacheWidth]와 같아야 캐시 키가 맞음.
  static Future<void> precache(Iterable<String?> urls, {int? decodeWidth}) {
    if (kIsWeb) return Future.value();
    final keys = {
      for (final raw in urls)
        if (raw != null && raw.trim().isNotEmpty) _normalizeUrl(raw),
    };
    return Future.wait(keys.map((url) => _precacheOne(url, decodeWidth)));
  }

  // [백엔드 수정] 카드 포스터 디코드 가로 픽셀 - 노트9 기준 소식 카드 약 360px,
  // 다이어리 티켓 약 650px에 태블릿 여유.
  static const int newsPosterDecodeWidth = 640;
  static const int diaryPosterDecodeWidth = 960;

  static Future<void> _precacheOne(String url, int? decodeWidth) {
    final done = Completer<void>();
    final ImageProvider base = CachedNetworkImageProvider(url);
    final stream = ResizeImage.resizeIfNeeded(
      decodeWidth,
      null,
      base,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    void finish() {
      if (done.isCompleted) return;
      done.complete();
      // 다음 프레임에 떼야 캐시에 남음(precacheImage와 같은 방식).
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => stream.removeListener(listener),
      );
    }

    listener = ImageStreamListener(
      (_, _) => finish(),
      onError: (_, _) => finish(),
    );
    stream.addListener(listener);
    return done.future;
  }

  /// 일부 KOPIS/기존 DB 데이터는 `www.example.com/path`처럼 스킴 없이
  /// 저장되어 ImageProvider가 로컬 경로로 해석할 수 있습니다.
  static String _normalizeUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return trimmed.isEmpty ? trimmed : 'https://$trimmed';
  }
}
