import 'package:flutter/material.dart';

import 'pressable_scale.dart';
import 'responsive_text.dart';

/// 종이 다이어리 톤 공통 색. 결산 보고서(summary_report.dart)의 크림 메모지·
/// 갈색 잉크와 같은 값이라 다른 탭도 여기서 가져다 씁니다.
abstract final class PaperColors {
  /// 메모지·카드 바탕(크림)
  static const card = Color(0xFFFFFBF3);

  /// 카드 안 칸·타일(크림보다 조금 진함)
  static const tile = Color(0xFFF7EFE2);

  /// 본문 잉크(진한 갈색)
  static const ink = Color(0xFF3B2A20);

  /// 보조 글자(옅은 갈색)
  static const muted = Color(0xFF8A7765);

  /// 도장·강조(빨간 잉크)
  static const stamp = Color(0xFFC8423A);

  /// 기본 마스킹테이프(반투명 베이지) - 결산 캘린더 테이프와 같은 색
  static const tape = Color(0xFFEDE3C8);

  /// 뜻이 있을 때만 쓰는 탁한 테이프 색
  static const tapeRose = Color(0xFFC4867A);
  static const tapeMustard = Color(0xFFC9A45C);
  static const tapeSage = Color(0xFF9DAF8E);
}

/// 비스듬히 붙인 마스킹테이프 한 조각. 양 끝은 손으로 찢은 톱니 모양.
///
/// [tint]를 주면 베이지 바탕에 그 색을 살짝만 섞습니다 - 원색 그대로 쓰면
/// 크림 종이·갈색 잉크 사이에서 혼자 떠 보여서.
class MaskingTape extends StatelessWidget {
  const MaskingTape({
    super.key,
    this.tint,
    this.width = 54,
    this.height = 15,
    this.angle = -0.06,
  });

  final Color? tint;
  final double width;
  final double height;
  final double angle;

  /// 베이지에 [tint]를 섞는 비율
  static const double _tintAmount = 0.38;

  @override
  Widget build(BuildContext context) {
    final t = tint;
    final color = t == null
        ? PaperColors.tape
        : Color.lerp(PaperColors.tape, t, _tintAmount)!;
    return Transform.rotate(
      angle: angle,
      child: CustomPaint(
        size: Size(width, height),
        painter: _TapePainter(color),
      ),
    );
  }
}

class _TapePainter extends CustomPainter {
  _TapePainter(this.color);

  final Color color;

  /// 찢긴 끝의 톱니 깊이·개수
  static const double _tooth = 2.2;
  static const int _teeth = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final step = h / _teeth;
    final path = Path()..moveTo(_tooth, 0);
    path.lineTo(w - _tooth, 0);
    // 오른쪽 끝 톱니(위→아래)
    for (var i = 0; i < _teeth; i++) {
      path.lineTo(i.isEven ? w : w - _tooth * .4, step * (i + .5));
      path.lineTo(w - _tooth, step * (i + 1));
    }
    path.lineTo(_tooth, h);
    // 왼쪽 끝 톱니(아래→위)
    for (var i = _teeth - 1; i >= 0; i--) {
      path.lineTo(i.isOdd ? 0 : _tooth * .4, step * (i + .5));
      path.lineTo(_tooth, step * i);
    }
    path.close();

    canvas.drawShadow(path, Colors.black.withValues(alpha: .25), 1, false);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: .86));
  }

  @override
  bool shouldRepaint(_TapePainter old) => old.color != color;
}

/// 내용 크기에 맞춰 늘어나는 마스킹테이프 조각(위에 글자·아이콘을 얹음).
class TapeStrip extends StatelessWidget {
  const TapeStrip({
    super.key,
    required this.child,
    this.tint,
    this.tintAmount = MaskingTape._tintAmount,
    this.angle = -0.025,
    this.padding = const EdgeInsets.fromLTRB(11, 3, 11, 3),
  });

  final Widget child;
  final Color? tint;

  /// 베이지에 [tint]를 섞는 비율. 바탕과 구분돼야 하는 버튼류는 더 진하게.
  final double tintAmount;
  final double angle;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = tint;
    final color = t == null
        ? PaperColors.tape
        : Color.lerp(PaperColors.tape, t, tintAmount)!;
    return Transform.rotate(
      angle: angle,
      child: CustomPaint(
        painter: _TapePainter(color),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 마스킹테이프 위에 적은 짧은 라벨(묶음 제목 등). 테이프 길이는 글자에 맞춰짐.
class TapeLabel extends StatelessWidget {
  const TapeLabel(
    this.text, {
    super.key,
    this.tint,
    this.angle = -0.025,
    this.fontSize = 12,
  });

  final String text;
  final Color? tint;
  final double angle;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return TapeStrip(
      tint: tint,
      angle: angle,
      child: Text(
        text,
        style: TextStyle(
          fontSize: context.sp(fontSize),
          fontWeight: FontWeight.w800,
          color: PaperColors.ink.withValues(alpha: .8),
          letterSpacing: 0.3,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}

/// 테이프 붙인 크림 메모지(빈 화면·오류·안내창 공통).
class PaperNote extends StatelessWidget {
  const PaperNote({
    super.key,
    required this.child,
    this.tapeTint,
    this.maxWidth = 300,
    this.angle = -0.015,
    this.padding = const EdgeInsets.fromLTRB(22, 26, 22, 18),
  });

  final Widget child;
  final Color? tapeTint;
  final double maxWidth;
  final double angle;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            padding: padding,
            decoration: BoxDecoration(
              color: PaperColors.card,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: PaperColors.ink.withValues(alpha: .08)),
              boxShadow: [
                BoxShadow(
                  color: PaperColors.ink.withValues(alpha: .14),
                  blurRadius: 9,
                  offset: const Offset(2, 5),
                ),
              ],
            ),
            child: child,
          ),
          Positioned(
            top: -7,
            left: 0,
            right: 0,
            child: Center(child: MaskingTape(tint: tapeTint)),
          ),
        ],
      ),
    );
  }
}

/// 메모지에 아이콘 + 제목 + 본문 + (있으면) 버튼을 얹은 안내.
class PaperNotice extends StatelessWidget {
  const PaperNotice({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.tapeTint,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color? tapeTint;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final label = actionLabel;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: PaperNote(
          tapeTint: tapeTint,
          // 글자가 화면 배율로 커지므로 폭도 같이 키움(안 그러면 어절 중간에서 줄바꿈)
          maxWidth: context.rs(300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: context.rs(34), color: PaperColors.muted),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.sp(15),
                  fontWeight: FontWeight.w900,
                  color: PaperColors.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.sp(12),
                  fontWeight: FontWeight.w600,
                  color: PaperColors.muted,
                  height: 1.5,
                ),
              ),
              if (label != null && onAction != null) ...[
                const SizedBox(height: 16),
                PaperButton(label: label, onTap: onAction!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum PaperButtonStyle {
  /// 갈색 잉크로 칠한 주 버튼
  primary,

  /// 테두리만 있는 보조 버튼
  outline,

  /// 글자만(취소 등 덜 눈에 띄어야 하는 것)
  quiet,

  /// 글자만, 빨간 잉크(되돌리기 어려운 동작)
  danger,
}

/// 종이 톤 버튼.
class PaperButton extends StatelessWidget {
  const PaperButton({
    super.key,
    required this.label,
    required this.onTap,
    this.style = PaperButtonStyle.primary,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onTap;
  final PaperButtonStyle style;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (style) {
      PaperButtonStyle.primary => (
        PaperColors.ink,
        PaperColors.card,
        Colors.transparent,
      ),
      PaperButtonStyle.outline => (
        Colors.transparent,
        PaperColors.ink,
        PaperColors.ink.withValues(alpha: .35),
      ),
      PaperButtonStyle.quiet => (
        Colors.transparent,
        PaperColors.muted,
        Colors.transparent,
      ),
      PaperButtonStyle.danger => (
        Colors.transparent,
        PaperColors.stamp,
        Colors.transparent,
      ),
    };
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : .5,
      child: PressableScale(
        onTap: onTap,
        enabled: enabled,
        pressScale: 0.95,
        tapScale: 1.02,
        child: Container(
          width: expand ? double.infinity : null,
          alignment: expand ? Alignment.center : null,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: border, width: 1.2),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: context.sp(13.5),
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

/// 확인창 버튼 하나. [value]는 눌렀을 때 [showPaperDialog]가 돌려주는 값
/// (취소처럼 null이어도 됨).
class PaperDialogAction<T> {
  const PaperDialogAction({
    required this.label,
    this.value,
    this.style = PaperButtonStyle.primary,
  });

  final String label;
  final T? value;
  final PaperButtonStyle style;
}

/// 기본 AlertDialog 대신 쓰는 메모지 확인창. 버튼은 [actions] 순서대로
/// 오른쪽 정렬로 놓입니다(주 버튼을 마지막에).
Future<T?> showPaperDialog<T>(
  BuildContext context, {
  required String title,
  String? message,
  String? emphasis,
  required List<PaperDialogAction<T>> actions,
  Color? tapeTint,
  bool barrierDismissible = true,
}) {
  final em = emphasis;
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) {
      // 폭은 글자 배율을 그대로, 여백·간격은 배율의 절반만 따라감 - 다 따르면
      // 페이지 밖이라 배율이 큰 태블릿에서 휑하고, 고정이면 빠듯함(폰은 배율 1 근처)
      final k = 1 + (context.rs(1) - 1) * .5;
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: PaperNote(
          tapeTint: tapeTint,
          maxWidth: context.rs(300),
          angle: 0,
          padding: EdgeInsets.fromLTRB(22 * k, 26 * k, 22 * k, 16 * k),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: context.sp(16),
                  fontWeight: FontWeight.w900,
                  color: PaperColors.ink,
                  height: 1.35,
                ),
              ),
              // 공연명 등 짚어줄 대상(굵게) - 빈 줄로 띄우는 대신 바로 위에 붙임
              if (em != null) ...[
                SizedBox(height: 10 * k),
                Text(
                  em,
                  style: TextStyle(
                    fontSize: context.sp(13.5),
                    fontWeight: FontWeight.w800,
                    color: PaperColors.ink,
                    height: 1.5,
                  ),
                ),
              ],
              if (message != null) ...[
                SizedBox(height: (em != null ? 4 : 10) * k),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: context.sp(13.5),
                    fontWeight: FontWeight.w500,
                    color: PaperColors.ink.withValues(alpha: .75),
                    height: 1.6,
                  ),
                ),
              ],
              SizedBox(height: 18 * k),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8 * k,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final a in actions)
                      PaperButton(
                        label: a.label,
                        style: a.style,
                        onTap: () => Navigator.pop(context, a.value),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 기본 SnackBar 대신 쓰는 갈색 잉크 쪽지.
void showPaperSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: PaperColors.ink,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      content: Text(
        message,
        style: const TextStyle(
          color: PaperColors.card,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

/// 프로필 동그라미. 사진이 없으면 크림 칸에 이름 첫 글자(게스트는 사람 아이콘).
///
/// 카카오 프로필 사진은 쓰지 않음 - 나중에 앱에서 직접 사진을 등록하면
/// [imageUrl]로 넘기면 됩니다.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.size,
    this.name,
    this.imageUrl,
  });

  final double size;
  final String? name;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final n = name?.trim() ?? '';
    final url = imageUrl;
    Widget inner;
    if (url != null && url.isNotEmpty) {
      inner = Image.network(url, fit: BoxFit.cover);
    } else if (n.isNotEmpty) {
      inner = Center(
        child: Text(
          n.characters.first.toUpperCase(),
          style: TextStyle(
            fontSize: size * .42,
            fontWeight: FontWeight.w900,
            color: PaperColors.ink.withValues(alpha: .7),
          ),
        ),
      );
    } else {
      inner = Icon(
        Icons.person_outline_rounded,
        size: size * .5,
        color: PaperColors.muted,
      );
    }
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: PaperColors.tile,
        shape: BoxShape.circle,
        border: Border.all(color: PaperColors.ink.withValues(alpha: .15)),
      ),
      child: inner,
    );
  }
}

/// 기다리는 동안 띄우는 메모지(검은 막 + 흰 스피너 대신). 닫을 때는 다른
/// 다이얼로그처럼 `Navigator.pop(context)`.
void showPaperLoading(BuildContext context, String message) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: PaperNote(
            maxWidth: context.rs(260),
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: PaperColors.muted,
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    message,
                    style: TextStyle(
                      fontSize: context.sp(14),
                      fontWeight: FontWeight.w800,
                      color: PaperColors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 시트 최대 폭 - 태블릿에서 화면 끝까지 늘어나지 않게.
const BoxConstraints kPaperSheetConstraints = BoxConstraints(maxWidth: 560);

/// 바텀시트는 DiaryPageFrame 밖이라 sp/rs가 화면 폭 배율을 그대로 써서
/// 태블릿에서 글자가 너무 커짐 - 확인창처럼 배율의 절반만 따르게 덮어씀.
Widget paperSheetScale(BuildContext context, Widget child) {
  return DiaryFrameScale(
    scale: 1 + (context.rs(1) - 1) * .5,
    marginEachSide: 0,
    child: child,
  );
}

/// 크림 종이로 된 선택 시트. [dismissible]이 false면 바깥 탭·드래그·뒤로가기로
/// 못 닫고 항목을 골라야만 닫힘.
Future<T?> showPaperSheet<T>(
  BuildContext context, {
  required String title,
  required List<Widget> Function(BuildContext context) rows,
  bool dismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: PaperColors.card,
    isDismissible: dismissible,
    enableDrag: dismissible,
    isScrollControlled: true,
    constraints: kPaperSheetConstraints,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (context) => paperSheetScale(
      context,
      PopScope(
        canPop: dismissible,
        child: SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.8,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: PaperColors.ink.withValues(alpha: .15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: context.sp(15),
                      fontWeight: FontWeight.w900,
                      color: PaperColors.ink,
                      height: 1.45,
                    ),
                  ),
                ),
                ...rows(context),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// [showPaperSheet]의 한 줄. 위에 옅은 구분선.
class PaperSheetRow extends StatelessWidget {
  const PaperSheetRow({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final String? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final tail = trailing;
    final lead = leading;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: PaperColors.ink.withValues(alpha: .08)),
          ),
        ),
        child: Row(
          children: [
            if (lead != null) ...[lead, const SizedBox(width: 14)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: context.sp(14.5),
                      fontWeight: FontWeight.w800,
                      color: PaperColors.ink,
                      height: 1.35,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      sub,
                      style: TextStyle(
                        fontSize: context.sp(12),
                        fontWeight: FontWeight.w600,
                        color: PaperColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (tail != null) ...[
              const SizedBox(width: 12),
              Text(
                tail,
                style: TextStyle(
                  fontSize: context.sp(14),
                  fontWeight: FontWeight.w800,
                  color: PaperColors.ink,
                ),
              ),
            ],
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: PaperColors.muted),
          ],
        ),
      ),
    );
  }
}
