import '../models/news_model.dart';

String newsCardKey(NewsModel item) => item.id != null
    ? 'feed:${item.id}'
    : 'concert:${item.concertId ?? item.concert}:${item.isFavoritedConcert}';

int findNewsCard(
  List<NewsModel> items, {
  String? key,
  String? concertId,
  String? name,
}) {
  final exact = key == null
      ? -1
      : items.indexWhere((item) => newsCardKey(item) == key);
  if (exact >= 0) return exact;
  final matches = <int>[
    for (var i = 0; i < items.length; i++)
      if (concertId != null
          ? items[i].concertId == concertId
          : name != null && items[i].concert == name)
        i,
  ];
  return matches.length == 1 ? matches.single : -1;
}
