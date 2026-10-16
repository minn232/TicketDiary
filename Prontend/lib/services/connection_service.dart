import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/connection.dart';
import 'api_client.dart';

// [백엔드 수정]
// 폰 맞대기 연결 API(`/social/connections`) 연동.
class ConnectionService {
  ConnectionService({ApiClient? client})
    : _client = client ?? ApiClient.instance;

  final ApiClient _client;

  // 서버 시계와의 차이 - 왕복이 가장 짧았던 응답 기준(요청·응답 가운데 시점을 server_time으로 봄)
  Duration? _clockOffset;
  Duration? _bestRoundTrip;

  void _sampleClock(DateTime sent, Map<String, dynamic> json) {
    final raw = json['server_time'] as String?;
    if (raw == null) return;
    final roundTrip = DateTime.now().difference(sent);
    if (_bestRoundTrip != null && roundTrip > _bestRoundTrip!) return;
    _bestRoundTrip = roundTrip;
    _clockOffset = DateTime.parse(raw).difference(sent.add(roundTrip ~/ 2));
  }

  /// 서버 시각을 이 폰 시각으로. 시계 차이를 아직 모르면 null(바로 시작).
  DateTime? toLocalTime(DateTime? serverTime) {
    final offset = _clockOffset;
    if (serverTime == null || offset == null) return null;
    return serverTime.subtract(offset).toLocal();
  }

  /// 연결된 상대 목록(최근에 만난 순).
  Future<List<UserConnection>> listConnections() async {
    final list = await _client.getList('/social/connections');
    return [
      for (final item in list)
        UserConnection.fromJson((item as Map).cast<String, dynamic>()),
    ];
  }

  /// 상대와의 연결 카드.
  Future<ConnectionCard> getCard(String peerUserId) async {
    final json = await _client.get('/social/connections/$peerUserId/card');
    return ConnectionCard.fromJson(json);
  }

  /// 연결 끊기.
  Future<void> deleteConnection(String peerUserId) async {
    await _client.delete('/social/connections/$peerUserId');
  }

  /// 연결 카드에서 상대에게 내 다음 공연을 보여줄지(`/settings`의 share_next_concert).
  Future<bool> getShareNextConcert() async {
    final json = await _client.get('/settings');
    return json['share_next_concert'] as bool? ?? true;
  }

  Future<void> setShareNextConcert(bool value) async {
    await _client.patch('/settings', body: {'share_next_concert': value});
  }

  static const _codeKey = 'nearby_code';
  static const _queueKey = 'nearby_sighting_queue';

  /// 내 BLE 광고 코드(8자리 hex). 서버 실패(오프라인) 시 아직 유효한 캐시를 씀.
  Future<String?> getNearbyCode() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final json = await _client.post('/social/nearby/code');
      await prefs.setString(_codeKey, jsonEncode(json));
      return json['code'] as String;
    } catch (_) {
      final cached = prefs.getString(_codeKey);
      if (cached == null) return null;
      final json = jsonDecode(cached) as Map<String, dynamic>;
      final validUntil = DateTime.parse(json['valid_until'] as String);
      return validUntil.isAfter(DateTime.now()) ? json['code'] as String : null;
    }
  }

  /// 맞댐 판정 올리기. 네트워크 실패면 저장해 두고 null 반환([flushQueuedSightings]로 나중에 올림).
  Future<SightingResult?> reportSighting({
    required String code,
    required int rssi,
    required DateTime seenAt,
  }) async {
    final body = {
      'code': code,
      'rssi': rssi,
      'seen_at': seenAt.toUtc().toIso8601String(),
    };
    try {
      final sent = DateTime.now();
      final json = await _client.post('/social/nearby/sightings', body: body);
      _sampleClock(sent, json);
      return SightingResult.fromJson(json);
    } on ApiException catch (e) {
      if (e.statusCode != -1) rethrow;
      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList(_queueKey) ?? [];
      await prefs.setStringList(_queueKey, [...queue, jsonEncode(body)]);
      return null;
    }
  }

  /// 판정을 올리고 waiting을 받은 뒤, 본 코드의 주인과 짝이 지어졌는지 확인.
  Future<SightingResult> getMatch(String code) async {
    final sent = DateTime.now();
    final json = await _client.get('/social/nearby/match?code=$code');
    _sampleClock(sent, json);
    return SightingResult.fromJson(json);
  }

  /// 오프라인 때 저장한 판정 올리기 - 서버가 72시간 안의 판정까지 받아줌.
  Future<void> flushQueuedSightings() async {
    final prefs = await SharedPreferences.getInstance();
    final queue = prefs.getStringList(_queueKey) ?? [];
    if (queue.isEmpty) return;
    final remaining = <String>[];
    for (final item in queue) {
      try {
        await _client.post(
          '/social/nearby/sightings',
          body: jsonDecode(item) as Map<String, dynamic>,
        );
      } on ApiException catch (e) {
        // 네트워크 실패만 다시 보관, 서버가 거절한 건(만료 등) 버림
        if (e.statusCode == -1) remaining.add(item);
      }
    }
    await prefs.setStringList(_queueKey, remaining);
  }

  /// 확인 대기 중인 연결 요청.
  Future<List<ConnectionRequest>> listRequests() async {
    final list = await _client.getList('/social/connections/requests');
    return [
      for (final item in list)
        ConnectionRequest.fromJson((item as Map).cast<String, dynamic>()),
    ];
  }

  /// "OO님 맞나요?" 확인 - 상대도 확인했으면 connected(연결 완료).
  Future<ConfirmResult> confirmRequest(String connectionId) async {
    final sent = DateTime.now();
    final json = await _client.post(
      '/social/connections/requests/$connectionId/confirm',
    );
    _sampleClock(sent, json);
    return ConfirmResult.fromJson(json);
  }

  Future<void> rejectRequest(String connectionId) async {
    await _client.delete('/social/connections/requests/$connectionId');
  }
}
