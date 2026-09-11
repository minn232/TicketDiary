import 'dart:io' show Platform;

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'responsive_text.dart';

/// 예매처별 표시 이름 + 상징 색 + 앱 아이콘(플레이스토어/공식 가이드에서 받은
/// 원본). 소식 상세(news_detail_overlay.dart)와 가로모드 다가오는 공연
/// 패널([LandscapeUpcomingTicketPanel])이 함께 씁니다.
const Map<String, ({String label, Color color, String icon})>
vendorTicketingInfo = {
  'MELON': (
    label: '멜론티켓',
    color: Color(0xFF00C639),
    icon: 'assets/images/vendors/melon.webp',
  ),
  'INTERPARK': (
    label: '인터파크',
    color: Color(0xFF3549FF),
    icon: 'assets/images/vendors/interpark.webp',
  ),
  'YES24': (
    label: '예스24',
    color: Color(0xFF000000),
    icon: 'assets/images/vendors/yes24.webp',
  ),
  'TICKETLINK': (
    label: '티켓링크',
    color: Color(0xFFE4002B),
    icon: 'assets/images/vendors/ticketlink.webp',
  ),
};

/// 각 예매처 앱의 실제 Android 패키지명(여러 개면 순서대로 시도).
/// AndroidManifest.xml `<queries>`에도 같은 목록 필요. 인터파크는 야놀자 앱
/// 우선 + 구버전 NOL 티켓 폴백.
const Map<String, List<String>> vendorAndroidPackages = {
  'INTERPARK': ['com.cultsotry.yanolja.nativeapp', 'com.interpark.app.ticket'],
  'YES24': ['com.yes24.ticket'],
  'TICKETLINK': ['kr.co.ticketlink.cne'],
  'MELON': ['com.iloen.melonticket'],
};

/// [vendorKey](예: 'YES24')의 예매 링크 [url]을 엽니다. Android는
/// android_intent_plus로 package를 지정해 앱 우선 실행을 시도하고(launch()
/// 전에 canResolveActivity()로 먼저 확인), 실패하면 브라우저로 폴백합니다.
Future<void> openVendorTicketing(String vendorKey, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;

  // http로 오는 링크가 많아서 https로 보정.
  final httpsUri = uri.scheme == 'http' ? uri.replace(scheme: 'https') : uri;
  final urlString = httpsUri.toString();

  if (!kIsWeb && Platform.isAndroid) {
    for (final package
        in vendorAndroidPackages[vendorKey] ?? const <String>[]) {
      final intent = AndroidIntent(
        action: 'action_view',
        data: urlString,
        package: package,
      );
      if (await intent.canResolveActivity() == true) {
        await intent.launch();
        return;
      }
    }
  }

  await launchUrl(httpsUri, mode: LaunchMode.externalApplication);
}

/// 예매처 버튼 하나(가로 꽉 참, 예매처 상징색). 왼쪽에 예매처 앱 아이콘.
/// [compact]가 true면 라벨을 "예스24"처럼 예매처 이름만 짧게 보여주고,
/// false(기본값)면 "예스24에서 예매하기"처럼 전체 문구를 씁니다.
class VendorTicketingButton extends StatelessWidget {
  final String vendor;
  final VoidCallback onTap;
  final double scale;
  final bool compact;

  const VendorTicketingButton({
    super.key,
    required this.vendor,
    required this.onTap,
    this.scale = 1.0,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final k = scale;
    final info = vendorTicketingInfo[vendor];
    final label = info?.label ?? vendor;
    final color = info?.color ?? const Color(0xFF5C4033);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(14 * k),
      child: InkWell(
        borderRadius: BorderRadius.circular(14 * k),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16 * k, vertical: 14 * k),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ClipOval(
                child: info != null
                    ? Image.asset(
                        info.icon,
                        width: 24 * k,
                        height: 24 * k,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        width: 24 * k,
                        height: 24 * k,
                        alignment: Alignment.center,
                        color: Colors.white,
                        child: Text(
                          vendor.isNotEmpty ? vendor.substring(0, 1) : '?',
                          style: TextStyle(
                            fontSize: context.sp(12),
                            fontWeight: FontWeight.w900,
                            color: color,
                          ),
                        ),
                      ),
              ),
              SizedBox(width: 9 * k),
              Text(
                compact ? label : '$label에서 예매하기',
                style: TextStyle(
                  fontSize: context.sp(14),
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [ticketingLinks]가 하나면 바로 열고, 여러 개면 [VendorTicketingButton]
/// 바텀시트로 골라서 엽니다. 비어있으면 아무 것도 안 함.
Future<void> openOrPickVendorTicketing(
  BuildContext context,
  Map<String, String>? ticketingLinks,
) async {
  final links = ticketingLinks;
  if (links == null || links.isEmpty) return;

  if (links.length == 1) {
    final entry = links.entries.first;
    await openVendorTicketing(entry.key, entry.value);
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                '예매처 선택',
                style: TextStyle(
                  fontSize: sheetContext.sp(15),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            for (final entry in links.entries) ...[
              VendorTicketingButton(
                vendor: entry.key,
                compact: true,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  openVendorTicketing(entry.key, entry.value);
                },
              ),
              const SizedBox(height: 9),
            ],
          ],
        ),
      ),
    ),
  );
}
