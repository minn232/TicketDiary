import 'dart:async';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

// [백엔드 수정]
// 폰 맞대기 BLE 판정. 기준값은 실측 결과(docs/NearbySharing_BLE_Measurement_2026-10-13.md 6장).
const _serviceUuid = 'c5f3a2e0-7b1d-4e9a-8f26-1d3c5b7a9e42';
const _manufacturerId = 0xFFFF;
const _modeFlag = 0x80;
// 서버가 "한쪽 -55 이상 + 다른 쪽 -62 이상"으로 짝지어서(기기마다 송신 세기 차이) -62부터 보고하고,
// 약하게 보고한 뒤 -55를 넘으면 한 번 더 보고
const _reportThreshold = -62;
const _strongThreshold = -55;
const _releaseThreshold = -65;
const _minPackets = 5;

/// 맞댐 판정 하나 - 상대 광고 코드와 판정 당시 1초 평균 RSSI.
class NearbyDetection {
  final String code;
  final int rssi;
  final DateTime seenAt;

  const NearbyDetection(this.code, this.rssi, this.seenAt);
}

enum NearbyEngineError {
  unsupported,
  permissionDenied,
  bluetoothOff,
  locationOff,
  failed,
}

class _Peer {
  final List<(DateTime, int)> recent = [];
  // 이번 접촉에서 마지막으로 보고한 1초 평균 (null이면 아직 안 보고)
  int? reported;

  double? average(DateTime now) {
    recent.removeWhere(
      (e) => now.difference(e.$1) > const Duration(seconds: 1),
    );
    if (recent.length < _minPackets) return null;
    return recent.map((e) => e.$2).reduce((a, b) => a + b) / recent.length;
  }
}

/// 내 코드를 아주 약한 세기로 광고하면서 같은 앱의 광고를 듣고, 맞댐 수준으로 1초 유지되면 알림.
class NearbyTapEngine extends ChangeNotifier {
  final _peripheral = FlutterBlePeripheral();
  final _ble = FlutterReactiveBle();
  final _peers = <String, _Peer>{};
  StreamSubscription<DiscoveredDevice>? _scanSub;
  final _detections = StreamController<NearbyDetection>.broadcast();

  bool running = false;
  NearbyEngineError? error;

  Stream<NearbyDetection> get detections => _detections.stream;

  /// 지금 신호가 잡히는 주변 기기 수 (맞대기 모드인 친구).
  int get nearbyCount => _peers.values.where((p) => p.recent.isNotEmpty).length;

  Future<void> start(String myCode) async {
    if (running) return;
    error = await _prepare();
    if (error != null) {
      notifyListeners();
      return;
    }
    try {
      await _peripheral.start(
        advertiseData: AdvertiseDataCore(
          serviceUuid: _serviceUuid,
          manufacturerId: _manufacturerId,
          manufacturerData: Uint8List.fromList([
            ..._hexBytes(myCode),
            _modeFlag,
          ]),
        ),
        androidSettings: AndroidAdvertiseSettings(
          advertiseSettings: AdvertiseSettings(
            advertiseMode: AdvertiseMode.advertiseModeLowLatency,
            txPowerLevel: AdvertiseTxPower.advertiseTxPowerUltraLow,
          ),
        ),
      );
      _scanSub = _ble
          .scanForDevices(
            withServices: [Uuid.parse(_serviceUuid)],
            scanMode: ScanMode.lowLatency,
          )
          .listen(
            (d) => _onDiscovered(d, myCode),
            onError: (Object _) {
              error = NearbyEngineError.failed;
              notifyListeners();
            },
          );
      running = true;
    } catch (_) {
      error = NearbyEngineError.failed;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await _peripheral.stop();
    } catch (_) {}
    _peers.clear();
    running = false;
    notifyListeners();
  }

  Future<NearbyEngineError?> _prepare() async {
    if (!await _peripheral.isSupported) return NearbyEngineError.unsupported;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ].request();
    if (statuses.values.any((s) => !s.isGranted)) {
      return NearbyEngineError.permissionDenied;
    }
    var status = await _waitReady(const Duration(seconds: 3));
    // 안드로이드 11 이하는 BLE 스캔에 위치 권한이 필요
    if (status == BleStatus.unauthorized) {
      if (!(await Permission.locationWhenInUse.request()).isGranted) {
        return NearbyEngineError.permissionDenied;
      }
      status = await _waitReady(const Duration(seconds: 3));
    }
    if (status == BleStatus.poweredOff) {
      // flutter_ble_peripheral의 enableBluetooth는 네이티브 NPE가 나서 시스템 켜기 창을 직접 띄움
      try {
        await const AndroidIntent(
          action: 'android.bluetooth.adapter.action.REQUEST_ENABLE',
        ).launch();
      } catch (_) {}
      status = await _waitReady(const Duration(seconds: 20));
    }
    if (status == BleStatus.poweredOff) return NearbyEngineError.bluetoothOff;
    if (status == BleStatus.locationServicesDisabled) {
      return NearbyEngineError.locationOff;
    }
    if (status != BleStatus.ready) return NearbyEngineError.failed;
    return null;
  }

  // 상태 스트림의 첫 값은 권한 허용·블루투스 켜기 전의 옛 값일 수 있어 ready가 될 때까지 잠깐 기다림
  Future<BleStatus> _waitReady(Duration timeout) async {
    var latest = BleStatus.unknown;
    try {
      await _ble.statusStream
          .map((s) => latest = s)
          .firstWhere((s) => s == BleStatus.ready)
          .timeout(timeout);
    } on TimeoutException catch (_) {}
    return latest;
  }

  void _onDiscovered(DiscoveredDevice device, String myCode) {
    // 제조사 데이터 앞 2바이트는 제조사 ID(리틀엔디언), 뒤는 [코드 4바이트, 모드 플래그]
    final raw = device.manufacturerData;
    if (raw.length < 7 || (raw[0] | raw[1] << 8) != _manufacturerId) return;
    if (raw[6] & _modeFlag == 0) return;
    final code = raw
        .sublist(2, 6)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    if (code == myCode) return;

    final now = DateTime.now();
    final peer = _peers.putIfAbsent(code, _Peer.new);
    final wasEmpty = peer.recent.isEmpty;
    peer.recent.add((now, device.rssi));
    final avg = peer.average(now);
    if (wasEmpty) notifyListeners();
    if (avg == null) return;
    // 한 접촉에서 최대 두 번(약하게 / 강해지면 한 번 더) 보고하고, 폰을 떼야 다시 판정
    final reported = peer.reported;
    if (reported != null && avg < _releaseThreshold) {
      peer.reported = null;
      return;
    }
    final firstReport = reported == null && avg >= _reportThreshold;
    final upgrade =
        reported != null &&
        reported < _strongThreshold &&
        avg >= _strongThreshold;
    if (firstReport || upgrade) {
      peer.reported = avg.round();
      _detections.add(NearbyDetection(code, avg.round(), now));
    }
  }

  static List<int> _hexBytes(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];

  @override
  void dispose() {
    stop();
    _detections.close();
    super.dispose();
  }
}
