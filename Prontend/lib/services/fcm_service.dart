import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'api_client.dart';
import 'notifications_service.dart';
import '../screen/notifications_screen.dart';
import '../widgets/tab_nav_coordinator.dart';
import '../widgets/responsive_text.dart';

/// Android 푸시 등록·포그라운드 표시·누르면 이동.
/// [백엔드 수정] 서버가 data(notification_id/type/ticket_id/concert_id)를 같이 보내서 누르면 알림함과
/// 같은 화면으로 바로 감. data가 없는 옛 푸시는 알림함을 엶.
class FcmService with WidgetsBindingObserver {
  FcmService._();
  static final instance = FcmService._();
  static const _native = MethodChannel('ticketdiary/notifications');
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final status = ValueNotifier<String>('알림 연결 확인 중');
  final changes = ValueNotifier<int>(0);
  bool _observing = false;
  bool _subscribed = false;
  bool _initialMessageChecked = false;
  bool _permissionRequested = false;
  bool _ready = false;
  bool _pendingOpen = false;

  /// 누른 푸시의 data(없으면 알림함으로).
  Map<String, dynamic> _pendingData = const {};
  bool _opening = false;
  Future<void>? _pending;
  Timer? _retry;
  int _attempts = 0;

  Future<void> init() {
    if (!supported) return Future.value();
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
      _native.setMethodCallHandler((call) async {
        if (call.method == 'tap') {
          final data = await _native.invokeMethod<String>('consumeTap');
          if (data != null) _queueOpen(_decode(data));
        }
      });
    }
    return _pending ??= _connect().whenComplete(() => _pending = null);
  }

  Future<void> _connect() async {
    try {
      final tapped = await _native.invokeMethod<String>('consumeTap');
      if (tapped != null) _queueOpen(_decode(tapped));
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      if (!_subscribed) {
        _subscribed = true;
        messaging.onTokenRefresh.listen(
          (_) => unawaited(registerForCurrentUser()),
          onError: (Object error) => _failed(error),
        );
        FirebaseMessaging.onMessage.listen((message) async {
          changes.value++;
          final notification = message.notification;
          if (notification == null) return;
          try {
            await _native.invokeMethod<void>('show', {
              'id':
                  message.messageId ??
                  DateTime.now().microsecondsSinceEpoch.toString(),
              'title': notification.title ?? 'Ticket Diary',
              'body': notification.body ?? '',
              'data': jsonEncode(message.data),
            });
          } catch (e) {
            debugPrint('[FCM] 알림 표시 실패: $e');
          }
        });
        FirebaseMessaging.onMessageOpenedApp.listen(
          (message) => _queueOpen(message.data),
        );
      }
      if (!_initialMessageChecked) {
        final initial = await messaging.getInitialMessage();
        _initialMessageChecked = true;
        if (initial != null) _queueOpen(initial.data);
      }
      if (!_permissionRequested) {
        _permissionRequested = true;
        await messaging.requestPermission();
      }
      final enabled = await _native.invokeMethod<bool>('enabled') ?? false;
      if (!enabled) {
        status.value = '휴대폰 알림이 꺼져 있어요';
        _retry?.cancel();
        return;
      }
      final token = await messaging.getToken();
      if (token == null) throw StateError('FCM 토큰 발급 대기');
      await ApiClient.instance.patch(
        '/settings/fcm-token',
        body: {'fcm_token': token},
      );
      status.value = '휴대폰 알림이 켜져 있어요';
      _attempts = 0;
      _retry?.cancel();
    } catch (e) {
      _failed(e);
    }
  }

  void _failed(Object error) {
    debugPrint('[FCM] 연결 실패: $error');
    status.value = '알림 연결을 확인하지 못했어요';
    _retry?.cancel();
    if (_attempts < 5) {
      _attempts++;
      _retry = Timer(
        Duration(seconds: 15 * _attempts),
        () => unawaited(init()),
      );
    }
  }

  Future<void> registerForCurrentUser() async {
    if (!supported || !_observing) return;
    // 계정 변경 전 등록 요청이 끝난 뒤 새 계정으로 반드시 재등록합니다.
    await _pending;
    await init();
  }

  Future<void> openSystemSettings() async {
    if (supported) await _native.invokeMethod<void>('settings');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _attempts = 0;
      changes.value++;
      unawaited(init());
    }
  }

  /// 첫 실행 계정 선택 및 스플래시 전환이 끝난 뒤에만 알림함 진입 허용.
  void markNavigationReady() {
    if (!supported) return;
    _ready = true;
    _openIfReady();
  }

  static Map<String, dynamic> _decode(String raw) {
    if (raw.isEmpty) return const {};
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : const {};
    } catch (_) {
      return const {};
    }
  }

  void _queueOpen([Map<String, dynamic> data = const {}]) {
    _pendingOpen = true;
    _pendingData = data;
    changes.value++;
    _openIfReady();
  }

  void _openIfReady() {
    if (!_ready || !_pendingOpen || _opening) return;
    final context =
        TabNavCoordinator.maybeInstance?.navigatorKey.currentContext;
    if (context == null) return;
    _pendingOpen = false;
    final data = _pendingData;
    _pendingData = const {};
    final type = data['type'] as String?;
    if (type != null) {
      _openFromPush(data, type);
      return;
    }
    _opening = true;
    unawaited(
      NotificationsScreen.show(
        context,
        frameScale: diaryScaleFromMediaQuery(context),
      ).whenComplete(() {
        _opening = false;
        _pendingOpen = false;
      }),
    );
  }

  /// 실패해도 무시 - 알림함에서 안 읽음으로 남을 뿐.
  Future<void> _markRead(String id) async {
    try {
      await NotificationsService().markRead(id);
      changes.value++;
    } catch (_) {}
  }

  /// 읽음 처리 후 알림함과 같은 화면으로. 갈 곳이 없는 알림(묶음 감상 메모 등)은 앱만 켜짐.
  void _openFromPush(Map<String, dynamic> data, String type) {
    String? field(String key) {
      final value = data[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final id = field('notification_id');
    if (id != null) unawaited(_markRead(id));
    final target = prepareNotificationTarget(
      type: type,
      ticketId: field('ticket_id'),
      concertId: field('concert_id'),
      title: field('title'),
    );
    if (target != null) TabNavCoordinator.instance.openTarget(target);
  }
}
