import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/services/api_client.dart';
import 'package:ticketdiary/services/ticket_service.dart';
import 'package:ticketdiary/services/connection_service.dart';
import 'package:ticketdiary/services/concert_detail_service.dart';
import 'package:ticketdiary/models/setlist.dart';
import 'support/fake_api.dart';

ResponseBody errorResponse(int status) => ResponseBody.fromString(
  '{"detail":"test failure"}',
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockStorage);
  group('티켓 요청 계약', () {
    test('생성 시 배송 대기와 날짜·가격·좌석을 전달한다', () async {
      final api = installApi((r) => {'id': 't', 'status': 'before_delivery'});
      final result = await TicketService().createTicket(
        concertId: 'c',
        deliveryDate: DateTime(2028, 1, 2),
        attendedDate: DateTime(2028, 2, 3),
        startTime: '18:00',
        ticketingSite: 'YES24',
        price: 0,
        seatType: 'R석',
        awaitingDelivery: true,
      );
      expect(result.status, 'before_delivery');
      expect(api.requests.single.method, 'POST');
      expect(api.requests.single.data, {
        'concert_id': 'c',
        'delivery_date': '2028-01-02T00:00:00.000',
        'attended_date': '2028-02-03T00:00:00.000',
        'start_time': '18:00',
        'ticketing_site': 'YES24',
        'price': 0,
        'seat_type': 'R석',
        'awaiting_delivery': true,
      });
    });
    test('부분 수정은 빈 문자열·false·빈 목록을 보존하고 미지정 필드를 제외한다', () async {
      final api = installApi((r) => {'id': 't', 'status': 'after_concert'});
      await TicketService().updateTicket(
        't',
        review: '',
        isFirstDay: false,
        concertPhotoUrls: [],
        clearTornAt: true,
        tornAt: DateTime(2028),
      );
      expect(api.requests.single.method, 'PATCH');
      expect(api.requests.single.data, {
        'review': '',
        'is_first_day': false,
        'concert_photo_urls': [],
        'torn_at': null,
      });
    });
    test('목록·단건·배송 완료·삭제가 올바른 경로를 사용한다', () async {
      final api = installApi(
        (r) => r.path == '/tickets'
            ? [
                {'id': 't', 'status': 'before_delivery'},
              ]
            : {'id': 't', 'status': 'before_concert'},
      );
      final service = TicketService();
      expect((await service.listTickets()).single.id, 't');
      expect((await service.getTicket('t')).id, 't');
      expect((await service.markDelivered('t')).status, 'before_concert');
      await service.deleteTicket('t');
      expect(api.requests.map((r) => '${r.method} ${r.path}'), [
        'GET /tickets',
        'GET /tickets/t',
        'POST /tickets/t/delivered',
        'DELETE /tickets/t',
      ]);
    });
    test('중복 등록 409를 도메인 오류로 바꾼다', () async {
      installApi((r) => errorResponse(409));
      await expectLater(
        TicketService().createTicket(kopisId: 'k'),
        throwsA(isA<TicketAlreadyRegisteredException>()),
      );
    });
    for (final status in [404, 500]) {
      test('수정·배송·삭제 오류 $status를 구분한다', () async {
        installApi((r) => errorResponse(status));
        final service = TicketService();
        final matcher = throwsA(
          status == 404 ? isA<TicketNotFoundException>() : isA<ApiException>(),
        );
        await expectLater(service.updateTicket('gone', review: 'a'), matcher);
        await expectLater(service.markDelivered('gone'), matcher);
        await expectLater(service.deleteTicket('gone'), matcher);
      });
    }
  });
  group('맞대기 캐시와 연결', () {
    test('광고 코드를 저장하고 서버 실패 시 만료되지 않은 코드만 사용한다', () async {
      var fail = false;
      installApi(
        (r) => fail
            ? errorResponse(503)
            : {'code': 'abcdef12', 'valid_until': '2099-01-01T00:00:00Z'},
      );
      final service = ConnectionService();
      expect(await service.getNearbyCode(), 'abcdef12');
      fail = true;
      expect(await service.getNearbyCode(), 'abcdef12');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'nearby_code',
        jsonEncode({'code': 'old', 'valid_until': '2000-01-01T00:00:00Z'}),
      );
      expect(await service.getNearbyCode(), isNull);
      await prefs.remove('nearby_code');
      expect(await service.getNearbyCode(), isNull);
    });
    test('관측 요청은 UTC로 전송하고 서버 시각 보정과 연결 확인을 처리한다', () async {
      final api = installApi(
        (r) => {
          'status': 'connected',
          'connection_id': 'pair',
          'peer': {'user_id': 'peer', 'nickname': '친구'},
          'server_time': DateTime.now().toUtc().toIso8601String(),
        },
      );
      final service = ConnectionService();
      expect(service.toLocalTime(DateTime.now()), isNull);
      final result = await service.reportSighting(
        code: 'abcdef12',
        rssi: -50,
        seenAt: DateTime(2028, 1, 1),
      );
      expect(result!.peer!.nickname, '친구');
      expect(
        api.requests.first.data['seen_at'],
        DateTime(2028, 1, 1).toUtc().toIso8601String(),
      );
      expect(service.toLocalTime(DateTime.now()), isNotNull);
      expect((await service.getMatch('abcdef12')).connectionId, 'pair');
      expect((await service.confirmRequest('pair')).connected, isTrue);
      await service.rejectRequest('pair');
      await service.deleteConnection('peer');
      expect(api.requests.last.path, '/social/connections/peer');
    });
    test('공유 설정은 기본 true이고 false 변경을 서버로 보낸다', () async {
      final api = installApi((r) => {});
      final service = ConnectionService();
      expect(await service.getShareNextConcert(), isTrue);
      await service.setShareNextConcert(false);
      expect(api.requests.last.data, {'share_next_concert': false});
    });
    test('보관한 관측 중 서버가 거절한 만료 항목도 큐에서 제거한다', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('nearby_sighting_queue', [
        jsonEncode({'code': 'old'}),
        jsonEncode({'code': 'new'}),
      ]);
      final api = installApi(
        (r) => r.data['code'] == 'old' ? errorResponse(400) : {},
      );
      await ConnectionService().flushQueuedSightings();
      expect(api.requests, hasLength(2));
      expect(prefs.getStringList('nearby_sighting_queue'), isEmpty);
    });
  });
  group('공연 상세', () {
    test('셋리스트 조회·편집은 티켓 경로를 사용하고 곡 속성을 보존한다', () async {
      final api = installApi(
        (r) => {
          'id': 's',
          'concert_id': 'c',
          'is_user_edited': r.method == 'PATCH',
          'songs':
              r.data?['songs'] ??
              [
                {'name': '기억', 'encore': true, 'artist': '넬'},
              ],
        },
      );
      final service = ConcertDetailService();
      expect((await service.getPreSetlist('t')).songs.single.artist, '넬');
      expect((await service.getRealSetlist('t')).songs.single.encore, isTrue);
      const songs = [SongEntry(name: '기억', encore: true, artist: '넬')];
      expect((await service.editPreSetlist('t', songs)).isUserEdited, isTrue);
      expect(
        (await service.editRealSetlist('t', songs)).songs.single.name,
        '기억',
      );
      expect(api.requests.last.data, {
        'songs': songs.map((s) => s.toJson()).toList(),
      });
      expect(api.requests.last.path, '/tickets/t/setlist');
    });
    test('미리듣기 quick 옵션과 아티스트 검색어 인코딩을 유지한다', () async {
      final api = installApi(
        (r) => r.path.contains('candidates')
            ? []
            : {
                'tracks': [
                  {
                    'track_name': '기억',
                    'artist_name': '넬',
                    'preview_url': 'https://example.com/song',
                  },
                ],
              },
      );
      final service = ConcertDetailService();
      expect(
        (await service.getPreviewTracks(
          't',
          quick: true,
        )).tracks.single.trackName,
        '기억',
      );
      expect(api.requests.last.path, '/tickets/t/preview-tracks?quick=true');
      expect(await service.searchArtistCandidates('t', 'A & B'), isEmpty);
      expect(api.requests.last.path, contains('A+%26+B'));
      expect(await service.searchAnchorCandidates('t', '기억 & 노래'), isEmpty);
      expect(
        api.requests.last.path,
        contains(Uri.encodeQueryComponent('기억 & 노래')),
      );
    });
  });
}
