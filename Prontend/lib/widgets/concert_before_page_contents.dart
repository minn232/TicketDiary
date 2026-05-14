import 'package:flutter/material.dart';

/// 공연 전(오버레이/스크린 공용) 페이지 내부 콘텐츠.
///
/// - 제목/서브 타이틀
/// - 2x2 포스트잇(공연정보/타임테이블/D-day/예상 셋리스트)
///
/// NOTE
/// - 오버레이에서는 [postItOpacity]에 애니메이션을 넘기면 포스트잇이 Fade-in 됩니다.
/// - 일반 스크린에서는 null로 두면 즉시 표시됩니다.
class ConcertBeforePageContents extends StatelessWidget {
  final String concertTitle;
  final Animation<double>? postItOpacity;
  final bool showCloseHint;

  const ConcertBeforePageContents({
    super.key,
    required this.concertTitle,
    this.postItOpacity,
    this.showCloseHint = true,
  });

  @override
  Widget build(BuildContext context) {
    final postItBody = _PostItGrid(concertTitle: concertTitle);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          concertTitle,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        Text(
          '공연 전',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Colors.black.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: postItOpacity == null
              ? postItBody
              : FadeTransition(opacity: postItOpacity!, child: postItBody),
        ),
        if (showCloseHint) ...[
          const SizedBox(height: 10),
          Text(
            '닫기: 포스트잇이 있는 페이지 바깥(포스터/불투명 영역)을 눌러주세요.',
            style: TextStyle(
              fontSize: 11,
              color: Colors.black.withValues(alpha: 0.45),
            ),
          ),
        ],
      ],
    );
  }
}

class _PostItGrid extends StatelessWidget {
  final String concertTitle;

  const _PostItGrid({required this.concertTitle});

  @override
  Widget build(BuildContext context) {
    const spacing = 14.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _PostItNote(
                      title: '공연 정보',
                      color: const Color(0xFFFFD6E8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _kv('공연명', concertTitle),
                          _kv('공연장', '콘서트홀'),
                          _kv('공연일', '2024.06.15'),
                          _kv('예매처', '예매 링크'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: spacing),
                  const Expanded(
                    child: _PostItNote(
                      title: '타임테이블',
                      color: Color(0xFFCFF5E7),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _TimeRow(time: '16:00', label: '입장'),
                          _TimeRow(time: '17:00', label: '오프닝'),
                          _TimeRow(time: '18:30', label: '메인'),
                          _TimeRow(time: '20:30', label: '종료'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: spacing),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _PostItNote(
                      title: 'D-day',
                      color: const Color(0xFFFFF6A6),
                      child: Center(
                        child: Text(
                          'D-12',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.0,
                            color: Colors.black.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: spacing),
                  const Expanded(
                    child: _PostItNote(
                      title: '예상 셋 리스트',
                      color: Color(0xFFD9E8FF),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Text('01. Intro', style: TextStyle(fontSize: 12)),
                          Text('02. Title Song', style: TextStyle(fontSize: 12)),
                          Text('03. Fan Favorite', style: TextStyle(fontSize: 12)),
                          Text('04. Encore', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static Widget _kv(String k, String v) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            k,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.black54,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            v,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _PostItNote extends StatelessWidget {
  final String title;
  final Color color;
  final Widget child;

  const _PostItNote({
    required this.title,
    required this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black.withValues(alpha: 0.12), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(2, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  final String time;
  final String label;

  const _TimeRow({required this.time, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(time, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

