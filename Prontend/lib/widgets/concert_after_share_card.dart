import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 공유 이미지 가로 픽셀 (인스타 권장 폭).
const double kShareImageWidth = 1080;

enum ShareCardAspect {
  original('원본', null),
  feed('4:5', 5 / 4),
  story('9:16', 16 / 9),

  /// 카카오톡 카드용 (선택지엔 없음).
  kakao('3:4', 4 / 3);

  /// 공유 시트에서 고를 수 있는 비율.
  static const choices = [original, feed, story];

  final String label;

  /// 세로/가로. null이면 페이지 비율 그대로.
  final double? ratio;
  const ShareCardAspect(this.label, this.ratio);
}

/// 카드 안 페이지/정보 띠 위치. 페이지 크기는 그대로 두고 배경 여백만 늘림.
class ShareCardGeometry {
  final Size card;
  final Rect page;
  final Rect band;

  const ShareCardGeometry({
    required this.card,
    required this.page,
    required this.band,
  });

  factory ShareCardGeometry.compute(Size page, ShareCardAspect aspect) {
    final margin = page.width * .06;
    final bandHeight = page.width * .11;
    final contentW = page.width + margin * 2;
    final contentH = margin + page.height + bandHeight + margin * .5;
    var cardW = contentW;
    var cardH = contentH;
    final ratio = aspect.ratio;
    if (ratio != null) {
      if (contentH / contentW < ratio) {
        cardH = contentW * ratio;
      } else {
        cardW = contentH / ratio;
      }
    }
    final pageRect = Rect.fromLTWH(
      (cardW - page.width) / 2,
      (cardH - contentH) / 2 + margin,
      page.width,
      page.height,
    );
    return ShareCardGeometry(
      card: Size(cardW, cardH),
      page: pageRect,
      band: Rect.fromLTWH(
        pageRect.left,
        pageRect.bottom,
        page.width,
        bandHeight,
      ),
    );
  }
}

/// 다이어리 가죽색 배경 위에 페이지 + 아래 정보 띠(날짜·공연장·로고).
class ConcertAfterShareCard extends StatelessWidget {
  final Size pageSize;
  final ShareCardAspect aspect;
  final Widget page;
  final String infoText;

  const ConcertAfterShareCard({
    super.key,
    required this.pageSize,
    required this.aspect,
    required this.page,
    required this.infoText,
  });

  static const Color _cream = Color(0xFFF4F1E1);

  @override
  Widget build(BuildContext context) {
    final g = ShareCardGeometry.compute(pageSize, aspect);
    final bandH = g.band.height;
    return SizedBox.fromSize(
      size: g.card,
      child: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF765840), Color(0xFF5C4033)],
                ),
              ),
            ),
          ),
          Positioned.fromRect(rect: g.page, child: page),
          Positioned.fromRect(
            rect: g.band,
            child: MediaQuery.withNoTextScaling(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      infoText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _cream.withValues(alpha: .92),
                        fontSize: bandH * .27,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  SizedBox(width: bandH * .2),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(bandH * .09),
                    child: Image.asset(
                      'assets/images/share/logo.png',
                      width: bandH * .38,
                      height: bandH * .38,
                    ),
                  ),
                  SizedBox(width: bandH * .1),
                  Text(
                    'TicketDiary',
                    style: TextStyle(
                      color: _cream,
                      fontSize: bandH * .25,
                      fontWeight: FontWeight.w800,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// [boundary]를 [width] 폭 PNG로 (화면 위 축소와 무관하게 boundary 논리 크기 기준).
Future<Uint8List> captureShareCardPng(
  RenderRepaintBoundary boundary, {
  double width = kShareImageWidth,
}) async {
  final ratio = width / math.max(1, boundary.size.width);
  final image = await boundary.toImage(pixelRatio: ratio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// 인스타 스토리 스티커용: 앞면/뒷면 카드를 살짝 기울여 겹친 한 장 (배경 투명).
/// 뒷면은 오른쪽 위, 앞면은 왼쪽 아래에 놓여 뒷면의 빈 왼쪽 아래를 덮음.
Future<Uint8List> composeTiltedPairPng(Uint8List front, Uint8List back) async {
  final a = await _decode(front);
  final b = await _decode(back);
  try {
    final w = math.max(a.width, b.width).toDouble();
    final h = math.max(a.height, b.height).toDouble();
    const frontAngle = -5 * math.pi / 180;
    const backAngle = 4 * math.pi / 180;
    // 앞면이 덮는 뒷면 폭 비율, 앞면이 내려가는 높이 비율.
    const overlap = .30;
    const drop = .38;
    Offset half(double angle) => Offset(
      (w * math.cos(angle).abs() + h * math.sin(angle).abs()) / 2,
      (w * math.sin(angle).abs() + h * math.cos(angle).abs()) / 2,
    );
    final fh = half(frontAngle);
    final bh = half(backAngle);
    final pad = w * .06;
    final backCenter = Offset(pad + fh.dx + w * (1 - overlap), pad + bh.dy);
    final frontCenter = Offset(pad + fh.dx, backCenter.dy + h * drop);
    final size = Size(
      backCenter.dx + bh.dx + pad,
      math.max(frontCenter.dy + fh.dy, backCenter.dy + bh.dy) + pad,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final shadow = Paint()
      ..color = const Color(0x59000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * .018);
    void draw(ui.Image image, Offset center, double angle) {
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: image.width.toDouble(),
        height: image.height.toDouble(),
      );
      canvas
        ..save()
        ..translate(center.dx, center.dy)
        ..rotate(angle)
        ..drawRect(rect.shift(Offset(0, w * .012)), shadow)
        ..drawImage(
          image,
          rect.topLeft,
          Paint()..filterQuality = FilterQuality.high,
        )
        ..restore();
    }

    draw(b, backCenter, backAngle);
    draw(a, frontCenter, frontAngle);
    final out = await recorder.endRecording().toImage(
      size.width.ceil(),
      size.height.ceil(),
    );
    try {
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      out.dispose();
    }
  } finally {
    a.dispose();
    b.dispose();
  }
}

Future<ui.Image> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}
