import 'package:flutter/material.dart';

import 'responsive_text.dart';

/// 공연 포스터 배경.
///
/// 백엔드에서 [imageUrl]로 실제 포스터 이미지를 받아오면 그 이미지를(살짝 투명하게)
/// 보여주고, 아직 연동 전이거나([imageUrl]이 null) 이미지 로딩에 실패하면
/// 예시용 그라데이션([PosterGradientPlaceholder])을 대신 보여줍니다.
///
/// "공연 전" 오버레이와 소식 상세 오버레이가 동일하게 사용합니다.
class PosterBackground extends StatelessWidget {
  final String? imageUrl;

  const PosterBackground({super.key, this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return const PosterGradientPlaceholder();
    }

    return Opacity(
      opacity: 0.85,
      child: Image.network(
        url,
        fit: BoxFit.cover,
        // KOPIS 등 CORS 헤더가 없는 이미지 서버는 웹에서 일반 로드가
        // 실패하므로, 실패 시 <img> 태그로 대신 렌더링합니다(웹 전용).
        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const PosterGradientPlaceholder();
        },
        errorBuilder: (context, error, stackTrace) =>
            const PosterGradientPlaceholder(),
      ),
    );
  }
}

/// 포스터 이미지가 없을 때 보여주는 예시용 그라데이션 배경.
class PosterGradientPlaceholder extends StatelessWidget {
  const PosterGradientPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xFF1F1C2C), const Color(0xFF928DAB)],
        ),
      ),
      child: Center(
        child: Text(
          'CONCERT\nPOSTER',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: context.sp(44),
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
            color: Colors.white.withValues(alpha: 0.12),
          ),
        ),
      ),
    );
  }
}
