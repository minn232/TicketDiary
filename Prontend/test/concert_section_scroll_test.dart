import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/models/ticket_info.dart';
import 'package:ticketdiary/widgets/concert_before_page_contents.dart';
import 'package:ticketdiary/widgets/concert_after_page_contents.dart';
import 'package:ticketdiary/widgets/section_scroll_view.dart';

ScrollPosition position(WidgetTester tester, String key) =>
    positionOf(tester, ValueKey(key));

ScrollPosition positionOf(WidgetTester tester, Key key) => tester
    .state<ScrollableState>(
      find
          .descendant(of: find.byKey(key), matching: find.byType(Scrollable))
          .first,
    )
    .position;

final longArtists = List.generate(60, (i) => '아티스트 $i').join('\n');

void main() {
  for (final size in [const Size(360, 640), const Size(560, 800)]) {
    testWidgets('공연 전 $size: 긴 목록은 각 칸만 스크롤하고 다른 칸은 고정된다', (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: size.width,
              height: size.height,
              child: ConcertBeforePageContents(
                concertTitle: '독립 스크롤 공연',
                ticketInfo: TicketInfo(
                  extraFields: {'아티스트': longArtists, '공연 유형': '페스티벌'},
                  timetable: List.generate(
                    60,
                    (i) => TimetableEntry(time: '18:00', label: '무대 $i'),
                  ),
                  setlist: List.generate(80, (i) => '노래 $i'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      const songs = 'before-section-예상 셋 리스트';
      const timetable = 'before-section-예상 타임테이블';
      const info = 'before-section-공연 정보';
      final poster = tester.getRect(find.text('▲ 공연 포스터'));
      final timetableRect = tester.getRect(
        find.byKey(const ValueKey(timetable)),
      );
      expect(position(tester, songs).maxScrollExtent, greaterThan(0));
      expect(position(tester, timetable).maxScrollExtent, greaterThan(0));
      await tester.drag(
        find.byKey(const ValueKey(songs)),
        const Offset(0, -100),
      );
      await tester.pumpAndSettle();
      expect(position(tester, songs).pixels, greaterThan(0));
      expect(position(tester, timetable).pixels, 0);
      expect(position(tester, info).pixels, 0);
      expect(tester.getRect(find.text('▲ 공연 포스터')), poster);
      expect(
        tester.getRect(find.byKey(const ValueKey(timetable))),
        timetableRect,
      );
      final songsOffset = position(tester, songs).pixels;
      await tester.drag(
        find.byKey(const ValueKey(timetable)),
        const Offset(0, -100),
      );
      await tester.pumpAndSettle();
      expect(position(tester, timetable).pixels, greaterThan(0));
      expect(position(tester, songs).pixels, songsOffset);
      await tester.ensureVisible(find.byKey(const ValueKey('before-artists')));
      await tester.pumpAndSettle();
      final infoOffset = position(tester, info).pixels;
      await tester.drag(
        find.byKey(const ValueKey('before-artists')),
        const Offset(0, -50),
      );
      await tester.pumpAndSettle();
      expect(position(tester, 'before-artists').pixels, greaterThan(0));
      expect(position(tester, info).pixels, infoOffset);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('공연 후 뒷면: 아티스트 목록·셋리스트 칸이 따로 스크롤된다', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const title = '독립 스크롤 뒷면';
    SharedPreferences.setMockInitialValues({
      'after_back_text_v1_local_after_${title}_1': List.generate(
        80,
        (i) => '타임테이블 $i',
      ).join('\n'),
      'after_back_text_v1_local_after_${title}_2': List.generate(
        80,
        (i) => '노래 $i',
      ).join('\n'),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 560,
            height: 700,
            child: ConcertAfterPageContents(
              concertTitle: title,
              ticketInfo: TicketInfo(extraFields: {'아티스트': longArtists}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(450, 350), const Offset(-220, 0));
    await tester.pumpAndSettle();
    // 뒷면은 칸 전체(제목 포함)가 칸별로 스크롤됨. 타임테이블이 짧으면(여기선 0줄) 공연 정보+
    // 타임테이블이 왼쪽 한 칸(0)으로 묶이고 셋리스트(2)는 따로
    const info = PageStorageKey('after_back_section_0');
    const songs = PageStorageKey('after_back_section_2');
    expect(positionOf(tester, songs).maxScrollExtent, greaterThan(0));
    await tester.drag(find.byKey(songs), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(positionOf(tester, songs).pixels, greaterThan(0));
    expect(positionOf(tester, info).pixels, 0);
    await tester.ensureVisible(find.byKey(const ValueKey('after-artists')));
    await tester.pumpAndSettle();
    final infoOffset = positionOf(tester, info).pixels;
    await tester.drag(
      find.byKey(const ValueKey('after-artists')),
      const Offset(0, -50),
    );
    await tester.pumpAndSettle();
    expect(position(tester, 'after-artists').pixels, greaterThan(0));
    expect(positionOf(tester, info).pixels, infoOffset);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('짧은 항목은 스크롤되지 않는다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          height: 100,
          child: SectionScrollView(
            key: ValueKey('short'),
            child: Text('짧은 내용'),
          ),
        ),
      ),
    );
    expect(position(tester, 'short').maxScrollExtent, 0);
  });
}
