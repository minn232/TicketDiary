import 'package:flutter/material.dart';

import 'app_network_image.dart';
import 'poster_fallback_gradient.dart';
import 'responsive_text.dart';
import 'vendor_ticketing_buttons.dart';
import 'venue_map_picker.dart';

/// 가로모드 2페이지 스프레드 왼쪽 동반 패널([DiaryLandscapeCoverPanel])에
/// 얹는 "다가오는 공연" 정적 요약. 큰 폴라로이드 사진(포스터 왼쪽 위
/// 모서리에 D-day 배지 + 지도 버튼) + 사진 폭에 맞춘 공연 정보 스티커.
/// 사진을 탭하면 예매처로 연결(하나면 바로 열고, 여러 곳이면
/// [openOrPickVendorTicketing]이 고를 수 있는 시트를 띄움).
///
/// 다이어리/소식/결산/설정 네 탭이 모두 이 위젯 하나로 같은 데이터를
/// 보여줍니다. 탭 가능한 부분은 전부 GlobalKey 없는 외부 링크 연결이라,
/// 다이어리 화면의 기존 오버레이 로직을 건드리지 않습니다.
class LandscapeUpcomingTicketPanel extends StatelessWidget {
  final String title;
  final DateTime? date;
  final String? posterImageUrl;
  final String? venue;
  final String? seat;
  final Map<String, String>? ticketingLinks;

  const LandscapeUpcomingTicketPanel({
    super.key,
    required this.title,
    required this.date,
    this.posterImageUrl,
    this.venue,
    this.seat,
    this.ticketingLinks,
  });

  static const Color _dDayBadgeAccent = Color(0xFFFF6B5E);
  // 노란 포스트잇 대신, 크림색 페이지 배경(0xFFF4F1E1)과 코랄색 D-day
  // 배지 둘 다와 잘 어울리는 차분한 세이지 그린.
  static const Color _infoStickerColor = Color(0xFFD9E4C7);

  static String _dDayLabel(DateTime? date) {
    if (date == null) return 'D-00';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = target.difference(today).inDays;
    if (diff > 0) return 'D-$diff';
    if (diff == 0) return 'D-DAY';
    return 'D+${-diff}';
  }

  /// 스티커 폭 — 패널 실제 폭 기준으로 계산해서, 화면 크기와 무관하게
  /// 항상 패널보다 살짝 좁게 유지됩니다(사진이 이제 패널 폭에 거의 꽉
  /// 차게 커져서, 패널 폭이 곧 사진 폭과 거의 같습니다).
  static double _stickerWidth(double availableWidth) => availableWidth - 4;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(context.rs(16)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 사진을 패널 폭에 거의 꽉 차게 키우되, [Expanded]로 남는 세로
          // 공간을 통째로 사진 칸에 배정하면 AspectRatio가 "안에 맞추기"로
          // 계산되면서 사진 위아래에 빈 공간이 생겼습니다(사진이 폭 기준
          // 으로 정해지고 세로는 그보다 짧아서). 대신 사진 폭만 이 값으로
          // 정하고, 배지·사진·스티커를 서로 적당히 띄워 쌓은 뒤 그 묶음
          // 전체를 페이지 세로 중앙에 둡니다 — 안쪽에 큰 빈틈이 안
          // 생깁니다. 폭은 패널 폭보다 살짝 좁혀서, 스파인 쪽 바인더
          // 링에 사진이 닿지 않게 합니다.
          final posterWidth = constraints.maxWidth - context.rs(14);
          final stickerWidth = _stickerWidth(posterWidth);
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: posterWidth,
                child: Row(
                  children: [
                    _buildDDayBadge(context),
                    const Spacer(),
                    if (venue != null && venue!.isNotEmpty)
                      _buildMapButton(context, venue!),
                  ],
                ),
              ),
              SizedBox(height: context.rs(12)),
              _buildBigPolaroid(context, posterWidth),
              SizedBox(height: context.rs(18)),
              _buildInfoSticker(context, stickerWidth),
            ],
          );
        },
      ),
    );
  }

  /// 큰 폴라로이드 사진 — 예매처 링크가 있으면 탭해서 예매처로 연결됩니다
  /// (하나면 바로 열고, 여러 곳이면 골라서).
  Widget _buildBigPolaroid(BuildContext context, double width) {
    final posterUrl = posterImageUrl;
    final links = ticketingLinks;
    final polaroid = Transform.rotate(
      angle: -0.02,
      child: Container(
        width: width,
        padding: EdgeInsets.all(context.rs(12)),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 16,
              offset: const Offset(4, 8),
            ),
          ],
        ),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: posterFallbackGradient(title),
              ),
            ),
            child: posterUrl != null && posterUrl.isNotEmpty
                ? AppNetworkImage(
                    posterUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_) => const SizedBox.shrink(),
                  )
                : null,
          ),
        ),
      ),
    );

    if (links == null || links.isEmpty) return polaroid;
    return GestureDetector(
      onTap: () => openOrPickVendorTicketing(context, links),
      child: polaroid,
    );
  }

  /// 사진 왼쪽 위 모서리에 얹는 D-day 배지 — 뜯어보는 탁상 달력처럼, 위쪽
  /// 색 밴드(다이어리 바인더 링을 닮은 작은 원 두 개 포함)와 아래쪽 흰
  /// 몸통(D-day 숫자)으로 나눕니다.
  Widget _buildDDayBadge(BuildContext context) {
    final width = context.rs(78);
    return Transform.rotate(
      angle: -0.08,
      child: Container(
        width: width,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(context.rs(10)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 8,
              offset: const Offset(2, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 달력 상단 색 밴드 — 작은 원 두 개로 다이어리 바인더 링을
            // 연상시킵니다.
            Container(
              width: double.infinity,
              color: _dDayBadgeAccent,
              padding: EdgeInsets.symmetric(vertical: context.rs(4)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildBadgeRing(context),
                  SizedBox(width: context.rs(10)),
                  _buildBadgeRing(context),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(
                vertical: context.rs(8),
                horizontal: context.rs(4),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _dDayLabel(date),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: context.sp(16),
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// D-day 배지 오른쪽의 지도 버튼 — 소식 상세(news_detail_overlay.dart)의
  /// "공연장" 버튼과 같은 [showVenueMapPicker]를 그대로 씁니다.
  Widget _buildMapButton(BuildContext context, String venue) {
    final size = context.rs(40);
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => showVenueMapPicker(context, venue),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            Icons.location_on,
            size: context.rs(20),
            color: const Color(0xFF5C4033),
          ),
        ),
      ),
    );
  }

  Widget _buildBadgeRing(BuildContext context) {
    final size = context.rs(6);
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
      ),
    );
  }

  /// 제목/장소·좌석이 적힌 공연 정보 스티커.
  Widget _buildInfoSticker(BuildContext context, double width) {
    final metaParts = <String>[
      if (venue != null && venue!.isNotEmpty) venue!,
      if (seat != null && seat!.isNotEmpty) seat!,
    ];

    return Transform.rotate(
      angle: 0.03,
      child: Container(
        width: width,
        padding: EdgeInsets.all(context.rs(14)),
        decoration: BoxDecoration(
          color: _infoStickerColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 6,
              offset: const Offset(2, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.sp(15),
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            if (metaParts.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: context.rs(4)),
                child: Text(
                  metaParts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.sp(12),
                    fontWeight: FontWeight.w600,
                    color: Colors.black54,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
