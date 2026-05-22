import 'package:flutter/material.dart';
import 'package:ticketdiary/widgets/diary_page_frame.dart';
import 'package:ticketdiary/widgets/diary_tabs.dart';

class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key});

  @override
  State<NewsScreen> createState() => _NewsScreenState();

  static const _items = <_NewsItemData>[
    _NewsItemData(concert: 'Concert', artist: 'Artist'),
    _NewsItemData(concert: 'Concert', artist: 'Artist'),
    _NewsItemData(concert: 'Concert', artist: 'Artist'),
    _NewsItemData(concert: 'Concert', artist: 'Artist'),
  ];
}

class _NewsScreenState extends State<NewsScreen> {
  static const Color _paperColor = Color(0xFFF4F1E1);

  @override
  Widget build(BuildContext context) {
    return DiaryPageFrame(
      isTabRoot: true,
      sideTabs: buildDiarySideTabs(context, active: DiaryTab.news),
      child: ColoredBox(
        color: _paperColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 18, 18, 18),
          child: LayoutBuilder(
            builder: (context, constraints) => _buildGrid(constraints),
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(BoxConstraints constraints) {
    const crossAxisCount = 2;
    const spacing = 16.0;
    final isExactly2x2 = NewsScreen._items.length == 4;

    final gridDelegate = isExactly2x2
        ? SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            // 2행이 화면 높이를 꽉 채우도록 아이템 높이를 직접 계산
            mainAxisExtent: (constraints.maxHeight - spacing) / 2,
          )
        : const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: 0.80,
          );

    return GridView.builder(
      padding: EdgeInsets.zero,
      physics: isExactly2x2 ? const NeverScrollableScrollPhysics() : null,
      gridDelegate: gridDelegate,
      itemCount: NewsScreen._items.length,
      itemBuilder: (context, index) {
        final item = NewsScreen._items[index];
        final angle = switch (index % 4) {
          0 => -0.015,
          1 => 0.012,
          2 => 0.010,
          _ => -0.012,
        };

        return _PolaroidCard(
          concert: item.concert,
          artist: item.artist,
          angle: angle,
        );
      },
    );
  }
}

class _NewsItemData {
  final String concert;
  final String artist;

  const _NewsItemData({required this.concert, required this.artist});
}

/// 폴라로이드 느낌 카드
/// - 흰 프레임 (공연전/공연후처럼 아래쪽 두꺼운 여백은 제거)
/// - 약간의 회전 + 그림자
class _PolaroidCard extends StatelessWidget {
  final String concert;
  final String artist;
  final double angle;

  const _PolaroidCard({
    required this.concert,
    required this.artist,
    required this.angle,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.black.withValues(alpha: 0.18),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 12,
              offset: const Offset(3, 6),
            ),
          ],
        ),
        child: Padding(
          // 폴라로이드 프레임(균일)
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                concert,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Colors.black.withValues(alpha: 0.35),
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 10),

              /// 사진 영역(placeholder)
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.12),
                      border: Border.all(
                        color: Colors.black.withValues(alpha: 0.12),
                        width: 1.2,
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.image_outlined,
                        color: Colors.black.withValues(alpha: 0.35),
                        size: 36,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              Text(
                artist,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Colors.black.withValues(alpha: 0.35),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
