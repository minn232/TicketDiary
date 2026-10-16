import 'package:flutter/material.dart';

/// 같은 단위의 값만 비교하는 가로 막대. 목표/달성률을 의미하지 않습니다.
class ReportMetricChart extends StatelessWidget {
  const ReportMetricChart({super.key, required this.rows, this.note});
  final List<(String, double, String)> rows;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final maximum = rows.fold<double>(0, (m, row) => row.$2 > m ? row.$2 : m);
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxHeight < 240 || box.maxWidth < 260) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final row in rows)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          if (rows.length > 1 || note != null)
                            Expanded(
                              child: Text(
                                row.$1,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF715849),
                                ),
                              ),
                            ),
                          const SizedBox(width: 4),
                          Flexible(
                            flex: 3,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                row.$3,
                                style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF5C4033),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: maximum == 0
                              ? 0
                              : (row.$2 / maximum).clamp(0, 1),
                          minHeight: 8,
                          backgroundColor: const Color(0xFFF0E5D5),
                          color: const Color(0xFF42685C),
                        ),
                      ),
                    ],
                  ),
                ),
              if (note != null)
                Tooltip(
                  message: note!,
                  child: Text(
                    note!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF715849),
                    ),
                  ),
                ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  note!,
                  style: const TextStyle(
                    color: Color(0xFF715849),
                    fontSize: 13,
                  ),
                ),
              ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final row in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.$1,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              color: Color(0xFF5C4033),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            row.$3,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF5C4033),
                            ),
                          ),
                          const SizedBox(height: 10),
                          LayoutBuilder(
                            builder: (_, box) => Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                width: maximum == 0
                                    ? 0
                                    : box.maxWidth *
                                          (row.$2 / maximum).clamp(0, 1),
                                height: 18,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF42685C),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ),
                            ),
                          ),
                          const Divider(height: 1, color: Color(0xFFD2BFA7)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const Text(
              '0 기준 · 막대 길이는 표시된 값에 비례',
              style: TextStyle(fontSize: 11, color: Color(0xFF715849)),
            ),
          ],
        );
      },
    );
  }
}
