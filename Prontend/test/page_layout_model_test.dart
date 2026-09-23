import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/models/page_layout.dart';
import 'package:ticketdiary/models/ticket_response.dart';

void main() {
  const json = {
    'version': 1,
    'canvas_aspect': 1.55,
    'items': [
      {
        'id': 'poster',
        'type': 'poster',
        'cx': 0.3,
        'cy': 0.4,
        'w': 0.34,
        'rot': 0.02,
        'z': 9,
        'pinned': false,
      },
      {
        'id': 'photo_a',
        'type': 'photo',
        'ref': 'https://example.com/a.jpg',
        'cx': 0.6,
        'cy': 0.8,
        'w': 0.3,
        'rot': -0.07,
        'z': 1,
        'pinned': true,
        'photo': {
          'w': 1024,
          'h': 768,
          'thumb_url': 'https://example.com/a_thumb.jpg',
          'taken_at': '2026:09:05 12:48:55',
        },
      },
    ],
  };

  test('백엔드 page_layout JSON 왕복 변환 (snake_case 유지)', () {
    final layout = PageLayout.tryParse(json)!;
    expect(layout.canvasAspect, 1.55);
    expect(layout.photos.single.pinned, isTrue);
    expect(layout.photos.single.photo!.aspect, closeTo(4 / 3, 1e-9));
    expect(layout.toJson(), json);
  });

  test('형식이 깨진 page_layout은 null (티켓 응답 파싱은 계속됨)', () {
    expect(PageLayout.tryParse(null), isNull);
    expect(PageLayout.tryParse({'items': 'oops'}), isNull);
    final ticket = TicketWithConcert.fromJson({
      'id': 't1',
      'status': 'after_concert',
      'page_layout': {
        'canvas_aspect': 1.5,
        'items': [
          {'type': 'envelope'},
        ],
      },
    });
    expect(ticket.pageLayout, isNull);
    expect(ticket.id, 't1');
  });
}
