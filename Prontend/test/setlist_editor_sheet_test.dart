import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ticketdiary/models/setlist.dart';
import 'package:ticketdiary/widgets/setlist_editor_sheet.dart';

Future<void> _openSheet(
  WidgetTester tester, {
  required List<SongEntry> initialSongs,
  List<String> artistNames = const [],
  required Future<void> Function(List<SongEntry>) onSave,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => SetlistEditorSheet.show(
                ctx,
                initialSongs: initialSongs,
                artistNames: artistNames,
                onSave: onSave,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('기존 곡이 보이고 곡 추가/삭제가 저장 시 반영된다', (tester) async {
    List<SongEntry>? saved;
    await _openSheet(
      tester,
      initialSongs: const [SongEntry(name: '곡1'), SongEntry(name: '곡2')],
      onSave: (songs) async {
        saved = songs;
      },
    );

    expect(find.text('곡1'), findsOneWidget);
    expect(find.text('곡2'), findsOneWidget);

    // 곡3 추가.
    await tester.enterText(find.byType(TextField).last, '곡3');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('곡3'), findsOneWidget);

    // 곡1 삭제(첫 번째 X 버튼).
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();
    expect(find.text('곡1'), findsNothing);

    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.map((s) => s.name).toList(), ['곡2', '곡3']);
    // 저장 성공 시 시트가 닫힘.
    expect(find.text('셋리스트 수정'), findsNothing);
  });

  testWidgets('저장 실패하면 시트가 안 닫히고 에러 문구가 보인다', (tester) async {
    await _openSheet(
      tester,
      initialSongs: const [SongEntry(name: '곡1')],
      onSave: (songs) async {
        throw Exception('네트워크 오류');
      },
    );

    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(find.text('저장하지 못했어요. 잠시 후 다시 시도해주세요.'), findsOneWidget);
    expect(find.text('곡1'), findsOneWidget);
  });

  // [백엔드 수정] 페스티벌(아티스트 2명 이상) 곡별 아티스트 배정 회귀 테스트.
  testWidgets('페스티벌이면 곡마다 아티스트를 지정할 수 있고 저장에 반영된다', (
    tester,
  ) async {
    List<SongEntry>? saved;
    await _openSheet(
      tester,
      initialSongs: const [SongEntry(name: '곡1', artist: '아티스트A')],
      artistNames: const ['아티스트A', '아티스트B'],
      onSave: (songs) async {
        saved = songs;
      },
    );

    // 기존 곡의 칩에 현재 아티스트가 보임.
    expect(find.text('아티스트A'), findsOneWidget);

    // 칩을 눌러 아티스트B로 변경.
    await tester.tap(find.text('아티스트A'));
    await tester.pumpAndSettle();
    // showMenu가 테스트 환경에서 아주 작은 앵커(1x1)로 위치를 잡다 보니
    // 계산된 좌표가 실제 렌더 트리와 살짝 어긋나 히트테스트 경고가 뜸(동작
    // 자체는 정상 - 아래 단언들로 확인) - warnIfMissed로 경고만 끔.
    await tester.tap(find.text('아티스트B').last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('아티스트A'), findsNothing);
    expect(find.text('아티스트B'), findsOneWidget);

    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.single.artist, '아티스트B');
  });
}
