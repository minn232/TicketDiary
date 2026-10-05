import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/services/favorites_store.dart';

Map<String, dynamic> _concert(String name, DateTime end) => {
  'name': name,
  'posterImageUrl': '',
  'id': '',
  'startDate': end.toIso8601String(),
  'endDate': end.toIso8601String(),
  'artistName': <String>[],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('종료된 찜 공연은 로드할 때 목록과 저장소에서 지워진다', () async {
    final now = DateTime.now().toUtc();
    SharedPreferences.setMockInitialValues({
      'favorite_concerts_v1': jsonEncode([
        _concert('지난 공연', now.subtract(const Duration(days: 3))),
        _concert('예정 공연', now.add(const Duration(days: 3))),
      ]),
    });

    final store = FavoritesStore.instance;
    await store.load();

    expect(store.favoriteConcerts.map((c) => c.name), ['예정 공연']);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('favorite_concerts_v1')!) as List;
    expect(saved.map((e) => e['name']), ['예정 공연']);
  });
}
