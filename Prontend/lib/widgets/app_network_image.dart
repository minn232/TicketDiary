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
  });

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      // 웹은 기존 동작 그대로 유지(위 클래스 doc 참고).
      return Image.network(
        url,
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
      imageUrl: url,
      fit: fit,
      width: width,
      height: height,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      placeholder: placeholderBuilder == null
          ? null
          : (context, url) => placeholderBuilder!(context),
      errorWidget: errorBuilder == null
          ? null
          : (context, url, error) => errorBuilder!(context),
    );
  }
}
