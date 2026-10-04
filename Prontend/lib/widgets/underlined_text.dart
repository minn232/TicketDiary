import 'package:flutter/material.dart';

// [백엔드 수정] 밑줄 링크용 공용 위젯 신규.
/// 텍스트 아래에 선 하나를 직접 그리는 밑줄 텍스트.
/// TextDecoration.underline은 한글/공백/기호가 서로 다른 폰트로 그려지면
/// 구간마다 밑줄 위치·두께가 달라져서 대신 씀.
class UnderlinedText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final Color? lineColor;

  const UnderlinedText(
    this.text, {
    super.key,
    required this.style,
    this.lineColor,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        lineColor ?? style.color ?? DefaultTextStyle.of(context).style.color;
    return Container(
      padding: const EdgeInsets.only(bottom: 1),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: color ?? Colors.black, width: 1),
        ),
      ),
      child: Text(text, style: style.copyWith(height: 1.1)),
    );
  }
}
