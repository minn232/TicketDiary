/// Report data is derived from the existing summary response; no extra totals
/// are estimated on the client.
class ReportMonth {
  const ReportMonth(this.month, this.count, this.spent);
  final DateTime month;
  final int count;
  final int spent;
  String get key => '${month.year}-${month.month.toString().padLeft(2, '0')}';
}

List<ReportMonth> reportMonths(
  Map<String, dynamic> data,
  String period, {
  DateTime? now,
}) {
  // Match the backend's Korean calendar, including around UTC month boundaries.
  final today = now ?? DateTime.now().toUtc().add(const Duration(hours: 9));
  final end = DateTime(today.year, today.month);
  final byMonth = <DateTime, ReportMonth>{};
  for (final row in (data['monthly_stats'] as List? ?? const [])) {
    final date = DateTime.tryParse('${row['month']}-01');
    if (date == null || date.isAfter(end)) continue;
    final month = DateTime(date.year, date.month);
    byMonth[month] = ReportMonth(
      month,
      (row['concert_count'] as num?)?.toInt() ?? 0,
      (row['spent'] as num?)?.toInt() ?? 0,
    );
  }
  final length = switch (period) {
    '6m' => 6,
    '1y' => 12,
    _ => null,
  };
  final first = length != null
      ? DateTime(end.year, end.month - length + 1)
      : (byMonth.keys.toList()..sort()).firstOrNull ?? DateTime(end.year);
  return [
    for (
      var month = first;
      !month.isAfter(end);
      month = DateTime(month.year, month.month + 1)
    )
      byMonth[month] ?? ReportMonth(month, 0, 0),
  ];
}

/// Ties occupy one podium position, with the backend's first-seen order used
/// to choose a representative. Each circle compares the per-artist count.
class ReportArtistGroup {
  const ReportArtistGroup(this.names, this.count, this.imageUrls);
  final List<String> names;
  final int count;
  final List<String?> imageUrls;
  String get name => names.first;
  String get label => labelAt(0);
  String labelAt(int index) => names.length == 1
      ? names[index]
      : '${names[index]} 외 ${names.length - 1}명';
}

List<ReportArtistGroup> reportArtistGroups(Map<String, dynamic> data) {
  final groups = <int, List<Map<String, dynamic>>>{};
  for (final row in (data['artists'] as List? ?? const [])) {
    final name = (row['name'] as String? ?? '').trim();
    final count = (row['count'] as num?)?.toInt() ?? 0;
    if (name.isEmpty || count <= 0) continue;
    groups.putIfAbsent(count, () => []).add({...row, 'name': name});
  }
  final counts = groups.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final count in counts.take(3))
      ReportArtistGroup(
        groups[count]!.map((a) => a['name'] as String).toList(),
        count,
        groups[count]!.map((a) => a['profile_image_url'] as String?).toList(),
      ),
  ];
}
