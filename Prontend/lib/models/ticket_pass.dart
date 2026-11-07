// [백엔드 수정] 2일권/3일권 등록용 신규(서버 ocr.py `_extract_pass_days`와 같은 규칙).

/// 전일권처럼 공연 전체 날짜 관람권.
const int passAllDays = 0;

final RegExp _passDaysRe = RegExp(
  r'(?<!\d)([1-9])\s*일\s*권|(?<![A-Za-z\d])([1-9])\s*-?\s*DAYS?(?![A-Za-z])',
  caseSensitive: false,
);
final RegExp _passAllRe = RegExp(
  r'전일권|올\s*패스|풀\s*패스|ALL\s*-?\s*PASS',
  caseSensitive: false,
);
const Map<String, int> _passWordDays = {'양일권': 2, '일일권': 1};

/// 좌석/가격표 등급명("2일권", "양일권", "3DAY", "전일권")의 관람 일수.
/// 전일권은 [passAllDays], 하루짜리거나 권종이 여러 개 섞여 있으면 null.
int? passDaysFromText(String? text) {
  if (text == null || text.isEmpty) return null;
  final found = <int>{
    for (final m in _passDaysRe.allMatches(text))
      int.parse(m.group(1) ?? m.group(2)!),
    for (final entry in _passWordDays.entries)
      if (text.contains(entry.key)) entry.value,
    if (_passAllRe.hasMatch(text)) passAllDays,
  };
  if (found.length != 1) return null;
  final days = found.single;
  return days == passAllDays || days >= 2 ? days : null;
}

const List<String> koreanWeekdays = ['월', '화', '수', '목', '금', '토', '일'];

String _two(int n) => n.toString().padLeft(2, '0');

/// 날짜 표기 통일용 - "09.04", [weekday]면 "09.04 (금)", [year]면 앞에 "2026.".
String passDateLabel(DateTime d, {bool year = false, bool weekday = false}) {
  final base = '${year ? '${d.year}.' : ''}${_two(d.month)}.${_two(d.day)}';
  return weekday ? '$base (${koreanWeekdays[d.weekday - 1]})' : base;
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// [days] 중 [count]일을 고르는 모든 조합(날짜순). [firstDay]로 시작하는 조합이
/// 있으면 그것만 - 티켓에 찍힌 날(예매 때 고른 날)이 보통 첫 관람일이라서.
List<List<DateTime>> passDayCombos(
  List<DateTime> days,
  int count, {
  DateTime? firstDay,
}) {
  final all = <List<DateTime>>[];
  void pick(int start, List<DateTime> chosen) {
    if (chosen.length == count) {
      all.add(chosen);
      return;
    }
    for (var i = start; i <= days.length - (count - chosen.length); i++) {
      pick(i + 1, [...chosen, days[i]]);
    }
  }

  if (count >= 1 && count <= days.length) pick(0, const []);
  if (firstDay == null) return all;
  final narrowed = all.where((c) => _sameDay(c.first, firstDay)).toList();
  return narrowed.isEmpty ? all : narrowed;
}
