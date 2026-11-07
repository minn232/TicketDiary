import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:ticketdiary/widgets/tab_nav_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ticketdiary/services/api_client.dart';

class FakeApi implements HttpClientAdapter {
  FakeApi(this.respond);
  final FutureOr<Object?> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final result = await respond(options);
    if (result is ResponseBody) return result;
    return ResponseBody.fromString(
      jsonEncode(result),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

FakeApi installApi(FutureOr<Object?> Function(RequestOptions) respond) {
  final api = FakeApi(respond);
  final old = ApiClient.instance.replaceHttpAdapter(api);
  addTearDown(() => ApiClient.instance.replaceHttpAdapter(old));
  return api;
}

void mockStorage() {
  SharedPreferences.setMockInitialValues({});
  final storage = <String, String>{};
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final key = args['key'] as String?;
        switch (call.method) {
          case 'read':
            return storage[key];
          case 'write':
            storage[key!] = args['value'] as String;
            return null;
          case 'delete':
            storage.remove(key);
            return null;
          case 'deleteAll':
            storage.clear();
            return null;
          case 'readAll':
            return storage;
          case 'containsKey':
            return storage.containsKey(key);
        }
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
}

Map<String, dynamic> concertJson(String id, {String? date}) => {
  'id': id,
  'name': '공연 $id',
  'artist_name': ['넬'],
  'venue': '공연장',
  'start_date': date ?? '2099-08-01',
  'end_date': date ?? '2099-08-01',
  'event_type': 'concert',
};
Map<String, dynamic> ticketJson(String id, String status) => {
  'id': id,
  'concert_id': id,
  'status': status,
  'price': 100000,
  'seat_type': 'R석',
  'concert': concertJson(
    id,
    date: status == 'after_concert' ? '2020-08-01' : null,
  ),
};
Object? sessionResponse(RequestOptions request) {
  if (request.path == '/auth/guest') {
    return {
      'access_token': 'test-access',
      'refresh_token': 'test-refresh',
      'user_id': 'test-user',
      'role': 'user',
    };
  }
  if (request.path == '/auth/me') {
    return {
      'id': 'test-user',
      'nickname': '테스터',
      'is_guest': true,
      'role': 'user',
    };
  }
  if (request.path == '/tickets') return [];
  if (request.path == '/social/feed') return [];
  if (request.path == '/social/artists') return {'artists': []};
  if (request.path == '/social/concerts') return {'concerts': []};
  return {};
}

GlobalKey<NavigatorState> initNavigation() {
  TabNavCoordinator.resetForTest();
  final key = GlobalKey<NavigatorState>();
  TabNavCoordinator.init(
    navigatorKey: key,
    routeBuilder: (_, _) => MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('destination')),
    ),
  );
  addTearDown(TabNavCoordinator.resetForTest);
  return key;
}
