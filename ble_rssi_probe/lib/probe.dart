import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

// 두 폰이 같은 앱을 켜면 서로 이 UUID로 광고하고, 이 UUID만 걸러서 스캔함
const probeServiceUuid = '7d2a0e1c-5b3f-4c8e-9a61-3f0b2d4c6e81';
// 0xFFFF는 블루투스 SIG가 테스트용으로 비워둔 제조사 ID
const probeManufacturerId = 0xFFFF;
// iOS는 광고에 제조사 데이터를 못 실어서(서비스 UUID·로컬 이름만 가능) 같은 4바이트를 로컬 이름에 hex 8자로 실음
// 플래그 3 + 서비스 UUID 18 + 이름 10 = 31바이트로 광고 패킷에 딱 들어감
final _iosNamePattern = RegExp(r'^[0-9A-F]{8}$');

const distanceLabels = ['맞댐', '10cm', '30cm', '1m', '3m', '5m'];

const txPowerNames = {
  AdvertiseTxPower.advertiseTxPowerHigh: 'HIGH',
  AdvertiseTxPower.advertiseTxPowerMedium: 'MEDIUM',
  AdvertiseTxPower.advertiseTxPowerLow: 'LOW',
  AdvertiseTxPower.advertiseTxPowerUltraLow: 'ULTRA_LOW',
};

class ProbeRow {
  ProbeRow({
    required this.at,
    required this.type,
    required this.label,
    required this.memo,
    required this.txPower,
    this.peerId = '',
    this.rssi,
    this.value,
    this.note = '',
  });

  final DateTime at;
  // rssi: 기록 중 받은 광고 1개 / bump: 내 충격 / peer_bump: 상대 충격 알림을 받은 시각
  final String type;
  final String label;
  final String memo;
  final String txPower;
  final String peerId;
  final int? rssi;
  // bump=충격 크기(m/s²), peer_bump=내 마지막 충격과의 시간차(ms)
  final double? value;
  // adv_restart 결과, scan_restart 이유 같은 진단 메모
  final String note;
}

class PeerState {
  PeerState(this.id);

  final String id;
  int? lastBumpCounter;
  final List<(DateTime, int)> recent = [];
  // 상대도 맞대기 모드인지 (광고 3번째 바이트 최상위 비트)
  bool holdMode = false;
  // 한 번 연결 판정이 나면 멀어졌다(기준-5dB 아래) 다시 올 때까지 재판정 안 함
  bool holdMatched = false;
  int matches = 0;
  // 마지막 패킷을 어디서 읽었는지 - mfr(안드로이드 광고) / name·cache·unknown(iOS 광고)
  String source = '';
  // 이번 접근에서 패킷 하나가 처음 기준을 넘은 시각 - 연결까지 걸린 시간 측정용
  DateTime? approachStart;
  DateTime? lastAboveAt;

  void add(DateTime at, int rssi) {
    recent.add((at, rssi));
    lastSeen = at;
    recent.removeWhere((e) => at.difference(e.$1) > const Duration(seconds: 2));
  }

  DateTime? lastSeen;

  bool everSeenWithin(DateTime now, int seconds) =>
      lastSeen != null && now.difference(lastSeen!) <= Duration(seconds: seconds);

  int? get lastRssi => recent.isEmpty ? null : recent.last.$2;

  // 최근 1초 평균 - 패킷 하나는 ±5dB씩 튀어서 화면엔 평균을 보여줌
  double? averageSince(DateTime now, Duration window) {
    final values = recent.where((e) => now.difference(e.$1) <= window).map((e) => e.$2).toList();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  int packetsLastSecond(DateTime now) => recent.where((e) => now.difference(e.$1) <= const Duration(seconds: 1)).length;
}

class SegmentStats {
  SegmentStats(this.key, this.values);

  final String key;
  final List<int> values;

  int get count => values.length;
  double get mean => values.reduce((a, b) => a + b) / values.length;
  int percentile(double p) {
    final sorted = [...values]..sort();
    return sorted[((sorted.length - 1) * p).round()];
  }
}

class Probe extends ChangeNotifier {
  final _peripheral = FlutterBlePeripheral();
  final _ble = FlutterReactiveBle();
  final myId = List.generate(3, (_) => Random().nextInt(256));

  String model = '';
  int sdkInt = 0;
  final bool isIOS = Platform.isIOS;
  // 화면·CSV 표시용 OS 정보 (안드로이드 SDK 29, iOS18.1)
  String osLabel = '';
  String? setupError;
  bool advertising = false;
  bool scanning = false;
  String accelSource = '선형가속도';

  // 2차 측정에서 맞댐/10cm 구분이 가장 잘 된 세기
  AdvertiseTxPower txPower = AdvertiseTxPower.advertiseTxPowerUltraLow;
  String label = distanceLabels.first;
  String memo = '';
  int recordSeconds = 20;
  double bumpThreshold = 7;
  bool holdMode = false;
  // 1초 유지 2차 측정: 옆면·뒷면 맞댐이 -51~-55라 -53이면 아슬아슬, 5cm는 -60~-62
  double holdThreshold = -55;
  ProbeRow? lastMatch;
  int matchCount = 0;

  // 화면 표시용: 지금 연결 판정이 유지 중인 상대가 있는지 (떼야 다음 맞댐을 셈)
  bool get holdLatched => peers.values.any((p) => p.holdMatched);

  DateTime? recordingUntil;
  final peers = <String, PeerState>{};
  final rows = <ProbeRow>[];
  final bumps = <ProbeRow>[];

  int _bumpCounter = 0;
  final _accelHistory = <(DateTime, double)>[];
  DateTime? _lastBumpAt;
  StreamSubscription? _scanSub;
  StreamSubscription? _accelSub;
  Timer? _tick;
  Timer? _watchdog;
  Timer? _autosave;

  // 광고 재시작이 겹치지 않게 - 흔들 때 충격이 0.5초마다 와서 stop/start가 겹쳐 실행되던 것이
  // 1차 측정 때 상대 수신율 급감(초당 6→0.7)의 원인 후보
  bool _advRestarting = false;
  bool _advRestartPending = false;
  DateTime? _lastScanStartAt;
  int _lowRateSeconds = 0;
  int scanRestarts = 0;
  int advRestartFailures = 0;
  int _savedRowCount = 0;
  String? autosavePath;

  String get myIdHex => _hex(myId);
  bool get recording => recordingUntil != null && DateTime.now().isBefore(recordingUntil!);
  // iOS는 송신 세기를 앱에서 못 바꿔서 고정값으로 표시
  String get txPowerName => isIOS ? 'IOS_DEFAULT' : txPowerNames[txPower]!;

  // 광고 끝 바이트: 최상위 비트=맞대기 모드, 나머지 7비트=충격 카운터
  int get _flagByte => (_bumpCounter & 0x7F) | (holdMode ? 0x80 : 0);

  // 이름 없이 온 패킷(스캔 응답이 빠진 경우 등)은 같은 기기의 직전 해석값을 씀
  final _decodedByDevice = <String, (String, int)>{};

  Future<void> init() async {
    if (isIOS) {
      final info = await DeviceInfoPlugin().iosInfo;
      model = info.modelName;
      osLabel = 'iOS${info.systemVersion}';
    } else {
      final info = await DeviceInfoPlugin().androidInfo;
      model = info.model;
      sdkInt = info.version.sdkInt;
      osLabel = 'SDK $sdkInt';
    }
    notifyListeners();

    setupError = await _ensurePermissions();
    if (setupError != null) {
      notifyListeners();
      return;
    }
    if (!await _peripheral.isSupported) {
      setupError = '이 기기는 BLE 광고를 지원하지 않음 (스캔만 가능)';
    }

    await _startAdvertising();
    await _startScan();
    _startAccel();
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkReceiveRate());
    _autosave = Timer.periodic(const Duration(seconds: 5), (_) => _autosaveCsv());
    // 화면 숫자(1초 평균, 남은 기록 시간)를 갱신하기 위한 틱
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => notifyListeners());
    notifyListeners();
  }

  Future<String?> _ensurePermissions() async {
    if (isIOS) {
      // iOS는 블루투스를 처음 쓸 때 시스템이 권한 창을 띄움 - 사용자가 누를 때까지 기다림
      final status = await _bleStatus(timeout: const Duration(seconds: 30));
      return switch (status) {
        BleStatus.ready => null,
        BleStatus.unauthorized => '설정 > 개인정보 보호 > 블루투스에서 이 앱을 허용해야 함',
        BleStatus.poweredOff => '블루투스를 켜야 함 (켠 뒤 앱 재실행)',
        _ => '블루투스 상태 확인 실패: ${status.name}',
      };
    }
    if (sdkInt >= 31) {
      final result = await [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ].request();
      if (result.values.any((s) => !s.isGranted)) return '블루투스 권한(근처 기기)을 허용해야 함';
    } else {
      // 안드로이드 11 이하(노트9)는 BLE 스캔에 정확한 위치 권한 + 위치 서비스 켜짐이 필요
      if (!(await Permission.location.request()).isGranted) return '위치 권한을 허용해야 함 (안드로이드 11 이하 BLE 스캔 조건)';
      if (await Permission.location.serviceStatus != ServiceStatus.enabled) {
        return '위치(GPS)를 켜야 함 - 꺼져 있으면 스캔 결과가 0건으로 나옴';
      }
    }
    // A15에서 enableBluetooth가 네이티브 NPE를 내서, 켜기 요청은 실패해도 넘어가고 실제 상태로만 판단
    if (await _bleStatus() != BleStatus.ready) {
      try {
        await _peripheral.enableBluetooth();
      } catch (_) {}
      if (await _bleStatus() != BleStatus.ready) return '블루투스를 켜야 함 (켠 뒤 앱 재실행)';
    }
    return null;
  }

  Future<BleStatus> _bleStatus({Duration timeout = const Duration(seconds: 5)}) =>
      _ble.statusStream.firstWhere((s) => s != BleStatus.unknown).timeout(timeout, onTimeout: () => BleStatus.unknown);

  // 선형가속도(중력 제거) 센서가 없는 기기(A15)는 일반 가속도에서 중력을 저역통과로 추정해 빼서 씀
  void _startAccel() {
    _accelSub = userAccelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
      (e) => _onAccel(e.x, e.y, e.z),
      onError: (Object _) {
        _accelSub?.cancel();
        accelSource = '가속도-중력추정';
        var gravity = [0.0, 0.0, 9.8];
        _accelSub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
          final raw = [e.x, e.y, e.z];
          gravity = [for (var i = 0; i < 3; i++) gravity[i] * 0.9 + raw[i] * 0.1];
          _onAccel(raw[0] - gravity[0], raw[1] - gravity[1], raw[2] - gravity[2]);
        });
        notifyListeners();
      },
      cancelOnError: true,
    );
  }

  Future<void> _startAdvertising() async {
    try {
      await _peripheral.start(
        advertiseData: isIOS
            ? AdvertiseDataCore(serviceUuid: probeServiceUuid, localName: _hex([...myId, _flagByte]))
            : AdvertiseDataCore(
                serviceUuid: probeServiceUuid,
                manufacturerId: probeManufacturerId,
                // [내 ID 3바이트, 충격 카운터] - 상대는 카운터가 바뀌는 순간을 내 충격 신호로 봄
                manufacturerData: Uint8List.fromList([...myId, _flagByte]),
              ),
        androidSettings: AndroidAdvertiseSettings(
          advertiseSettings: AdvertiseSettings(
            advertiseMode: AdvertiseMode.advertiseModeLowLatency,
            txPowerLevel: txPower,
          ),
        ),
      );
      advertising = true;
    } catch (e) {
      advertising = false;
      setupError = '광고 시작 실패: $e';
    }
  }

  Future<void> _restartAdvertising() async {
    if (_advRestarting) {
      // 진행 중인 재시작이 끝나면 최신 카운터로 한 번 더 - 카운터 변화는 놓치지 않음
      _advRestartPending = true;
      return;
    }
    _advRestarting = true;
    try {
      do {
        _advRestartPending = false;
        final started = DateTime.now();
        String? error;
        try {
          await _peripheral.stop();
        } catch (e) {
          error = 'stop: $e';
        }
        await _startAdvertising();
        if (!advertising) error = setupError;
        bool? onAir;
        try {
          onAir = await _peripheral.isAdvertising;
        } catch (_) {}
        if (error != null || onAir == false) advRestartFailures++;
        rows.add(
          _row(
            'adv_restart',
            value: DateTime.now().difference(started).inMilliseconds.toDouble(),
            note: '${error ?? 'ok'} onAir=$onAir counter=$_bumpCounter',
          ),
        );
      } while (_advRestartPending);
    } finally {
      _advRestarting = false;
    }
    notifyListeners();
  }

  // 상대가 보이는데 초당 수신이 2개 미만으로 5초 이상 이어지면 스캔을 다시 시작
  // 안드로이드는 30초에 스캔 시작 5회를 넘기면 막아서 재시작은 15초에 한 번까지만
  void _checkReceiveRate() {
    final now = DateTime.now();
    // 앱을 다시 켜면 ID가 바뀌어서, 30초 동안 안 보인 상대는 목록에서 뺌
    peers.removeWhere((_, p) => !p.everSeenWithin(now, 30));
    for (final p in peers.values) {
      p.recent.removeWhere((e) => now.difference(e.$1) > const Duration(seconds: 2));
      // 1초 평균 RSSI도 같이 - 기록 버튼 안 눌러도 가까이 두기·걷기 구간의 거리 분포를 볼 수 있게
      rows.add(
        _row(
          'rate',
          peerId: p.id,
          rssi: p.averageSince(now, const Duration(seconds: 1))?.round(),
          value: p.packetsLastSecond(now).toDouble(),
        ),
      );
    }
    // 가만히 있을 때·들고 있을 때의 평소 흔들림 크기 - 재확인 기준을 얼마나 낮출 수 있는지 볼 기준선
    rows.add(_row('accel_peak', value: _accelPeak(now, const Duration(seconds: 1))));
    final active = peers.values;
    if (active.isEmpty) return;
    final total = active.map((p) => p.packetsLastSecond(now)).fold<int>(0, (a, b) => a + b);
    _lowRateSeconds = total < 2 ? _lowRateSeconds + 1 : 0;
    if (_lowRateSeconds >= 5 &&
        (_lastScanStartAt == null || now.difference(_lastScanStartAt!) > const Duration(seconds: 15))) {
      _lowRateSeconds = 0;
      scanRestarts++;
      rows.add(_row('scan_restart', value: total.toDouble(), note: '초당 2개 미만 5초 지속'));
      _scanSub?.cancel();
      _startScan();
    }
  }

  // 공유 없이도 adb로 바로 가져갈 수 있게 앱 외부 저장소에 계속 덮어씀
  // (/sdcard/Android/data/<패키지>/files - 권한 필요 없고 adb pull 가능)
  Future<void> _autosaveCsv() async {
    if (rows.length == _savedRowCount) return;
    try {
      // iOS는 문서 폴더 - Info.plist 파일 공유 설정으로 파일 앱 > 나의 iPhone > BLE 실측에 보임
      final dir = isIOS ? await getApplicationDocumentsDirectory() : await getExternalStorageDirectory();
      if (dir == null) return;
      _sessionStamp ??= _fileStamp(DateTime.now());
      final file = File('${dir.path}/rssi_${model.replaceAll(' ', '_')}_${myIdHex}_$_sessionStamp.csv');
      await file.writeAsString(_csvContent());
      _savedRowCount = rows.length;
      autosavePath = file.path;
    } catch (_) {}
  }

  String? _sessionStamp;

  Future<void> _startScan() async {
    _lastScanStartAt = DateTime.now();
    // 스캔을 끄고 켜면 안드로이드가 30초 5회 제한을 걸어서 한 번 켜고 계속 유지
    // reactive_ble은 안드로이드에서 CALLBACK_TYPE_ALL_MATCHES로 스캔해서 광고 패킷마다 결과가 옴
    _scanSub = _ble
        .scanForDevices(
          withServices: [Uuid.parse(probeServiceUuid)],
          scanMode: ScanMode.lowLatency,
          requireLocationServicesEnabled: !isIOS && sdkInt < 31,
        )
        .listen(
          _onDiscovered,
          onError: (Object e) {
            scanning = false;
            setupError = '스캔 오류: $e';
            notifyListeners();
          },
        );
    scanning = true;
  }

  // 광고에서 (상대 ID, 끝 바이트)와 어디서 읽었는지를 꺼냄
  // 안드로이드 광고는 제조사 데이터, iOS 광고는 로컬 이름 - 스캔하는 쪽은 OS 상관없이 둘 다 읽음
  (String, int, String) _decode(DiscoveredDevice r) {
    // reactive_ble은 제조사 데이터 앞에 제조사 ID 2바이트(리틀엔디언)를 붙여서 줌
    final raw = r.manufacturerData;
    if (raw.length >= 6 && (raw[0] | raw[1] << 8) == probeManufacturerId) {
      return (_hex(raw.sublist(2, 5)), raw[5], 'mfr');
    }
    if (_iosNamePattern.hasMatch(r.name)) {
      final decoded = (r.name.substring(0, 6), int.parse(r.name.substring(6), radix: 16));
      _decodedByDevice[r.id] = decoded;
      return (decoded.$1, decoded.$2, 'name');
    }
    final cached = _decodedByDevice[r.id];
    if (cached != null) return (cached.$1, cached.$2, 'cache');
    // 이름을 한 번도 못 받은 iOS 기기 - RSSI는 남기도록 기기 ID로 임시 구분 (모드·충격은 모름)
    final fallback = 'X${r.id.replaceAll(RegExp('[^0-9A-Fa-f]'), '').toUpperCase().padLeft(5, '0').substring(0, 5)}';
    return (fallback, 0, 'unknown');
  }

  void _onDiscovered(DiscoveredDevice r) {
    final (peerId, flags, source) = _decode(r);
    if (peerId == myIdHex) return;

    final now = DateTime.now();
    final peer = peers.putIfAbsent(peerId, () => PeerState(peerId));
    peer.add(now, r.rssi);
    peer.source = source;

    final counter = flags & 0x7F;
    peer.holdMode = flags & 0x80 != 0;
    if (peer.lastBumpCounter != null && peer.lastBumpCounter != counter) {
      // 같은 시계(내 폰)로 잰 "내 충격 → 상대 충격 알림 수신" 간격
      // 두 폰 시계를 맞추지 않아도 오프라인 매칭에 걸리는 시간을 볼 수 있음
      final delta = _lastBumpAt == null ? null : now.difference(_lastBumpAt!).inMilliseconds;
      final row = _row(
        'peer_bump',
        peerId: peerId,
        rssi: r.rssi,
        value: delta != null && delta <= 3000 ? delta.toDouble() : null,
      );
      rows.add(row);
      bumps.insert(0, row);
      // 상대 충격은 수신보다 최대 약 330ms 먼저 일어나서(2차 측정), 수신 시점 기준 700ms 전까지 봄
      // 내 충격이 기준(10) 아래라 안 잡힌 경우에 더 낮은 기준으로 살릴 수 있는지 판단할 데이터
      final peak = _accelPeak(now, const Duration(milliseconds: 700));
      final mine = delta != null && delta <= 700;
      final recheck = _row('recheck', peerId: peerId, rssi: r.rssi, value: peak, note: mine ? '내 충격 있음' : '내 충격 없음');
      rows.add(recheck);
      bumps.insert(0, recheck);
      // 빠른 경로: 상대가 부딪힘 + 내 쪽도 약하게나마 흔들림(≥3) + 맞댐 수준 RSSI
      if (holdMode && peer.holdMode && peak >= 3 && r.rssi >= -55 && !peer.holdMatched) {
        peer.holdMatched = true;
        final row = _row('bump_match', peerId: peerId, rssi: r.rssi, value: peak, note: '부딪힘 빠른 연결');
        rows.add(row);
        bumps.insert(0, row);
        lastMatch = row;
        matchCount++;
        peer.matches++;
      }
    }
    peer.lastBumpCounter = counter;

    // iOS 광고에서 온 패킷은 출처를 남김 - 이름 없이 온(cache) 비율로 iOS 광고가 잘 읽히는지 봄
    if (recording) rows.add(_row('rssi', peerId: peerId, rssi: r.rssi, note: source == 'mfr' ? '' : source));
    _checkHold(peer, now, r.rssi);
  }

  // 맞대고 1초 유지 판정: 둘 다 맞대기 모드 + 최근 1초 평균 RSSI ≥ 기준(패킷 5개 이상)
  // 상대 쪽도 같은 판정을 독립적으로 함 - 실제 기능에선 양쪽 판정을 서버에서 짝지음
  void _checkHold(PeerState peer, DateTime now, int rssi) {
    if (!holdMode || !peer.holdMode) {
      peer.approachStart = null;
      peer.holdMatched = false;
      return;
    }
    // 접근 시작 = 기준을 넘는 패킷이 1초 이상 끊기지 않고 이어진 구간의 첫 패킷
    if (rssi >= holdThreshold) {
      if (peer.approachStart == null ||
          peer.lastAboveAt == null ||
          now.difference(peer.lastAboveAt!) > const Duration(seconds: 1)) {
        peer.approachStart = now;
      }
      peer.lastAboveAt = now;
    }
    final window = peer.recent.where((e) => now.difference(e.$1) <= const Duration(seconds: 1)).toList();
    if (window.isEmpty) return;
    final avg = window.map((e) => e.$2).reduce((a, b) => a + b) / window.length;
    if (peer.holdMatched) {
      // 3차 판정 실측: 몇 cm만 떼면 -55 근처라 기준-5(-58)로는 해제가 안 돼 다음 맞댐을 못 셌음
      if (avg < holdThreshold - 3) {
        peer.holdMatched = false;
        peer.approachStart = null;
        rows.add(_row('hold_release', peerId: peer.id, rssi: avg.round(), value: avg));
      }
      return;
    }
    if (window.length >= 5 && avg >= holdThreshold) {
      peer.holdMatched = true;
      final took = peer.approachStart == null ? null : now.difference(peer.approachStart!).inMilliseconds;
      final row = _row(
        'hold_match',
        peerId: peer.id,
        rssi: avg.round(),
        value: took?.toDouble(),
        note: '1초 평균 ${avg.toStringAsFixed(1)} 패킷 ${window.length}개',
      );
      rows.add(row);
      bumps.insert(0, row);
      lastMatch = row;
      matchCount++;
      peer.matches++;
      notifyListeners();
    } else if (avg < holdThreshold - 5) {
      peer.approachStart = null;
    }
  }

  Future<void> setHoldMode(bool value) async {
    holdMode = value;
    for (final p in peers.values) {
      p.holdMatched = false;
      p.approachStart = null;
    }
    rows.add(_row('hold_mode', value: value ? 1 : 0));
    await _restartAdvertising();
  }

  void setHoldThreshold(double value) {
    holdThreshold = value;
    notifyListeners();
  }

  void _onAccel(double x, double y, double z) {
    final magnitude = sqrt(x * x + y * y + z * z);
    final now = DateTime.now();
    _accelHistory.add((now, magnitude));
    _accelHistory.removeWhere((e) => now.difference(e.$1) > const Duration(seconds: 2));
    if (magnitude < bumpThreshold) return;
    // 한 번 부딪힐 때 여러 샘플이 연속으로 넘으니 500ms 안의 것은 같은 충격으로 봄
    if (_lastBumpAt != null && now.difference(_lastBumpAt!) < const Duration(milliseconds: 500)) return;
    _lastBumpAt = now;
    _bumpCounter++;

    final nearest = _nearestPeer(now);
    final row = _row(
      'bump',
      peerId: nearest?.id ?? '',
      rssi: nearest?.averageSince(now, const Duration(seconds: 1))?.round(),
      value: magnitude,
    );
    rows.add(row);
    bumps.insert(0, row);
    _restartAdvertising();
  }

  // 최근 구간의 최대 가속도 - 상대 충격 신호를 받았을 때 내 쪽도 약하게나마 부딪혔는지 재확인용
  double _accelPeak(DateTime now, Duration window) =>
      _accelHistory.where((e) => now.difference(e.$1) <= window).fold<double>(0, (m, e) => max(m, e.$2));

  PeerState? _nearestPeer(DateTime now) {
    PeerState? best;
    double? bestRssi;
    for (final p in peers.values) {
      final avg = p.averageSince(now, const Duration(seconds: 1));
      if (avg != null && (bestRssi == null || avg > bestRssi)) {
        best = p;
        bestRssi = avg;
      }
    }
    return best;
  }

  ProbeRow _row(String type, {String peerId = '', int? rssi, double? value, String note = ''}) => ProbeRow(
    at: DateTime.now(),
    type: type,
    label: label,
    memo: memo,
    txPower: txPowerName,
    peerId: peerId,
    rssi: rssi,
    value: value,
    note: note,
  );

  void startRecording() {
    recordingUntil = DateTime.now().add(Duration(seconds: recordSeconds));
    notifyListeners();
  }

  void stopRecording() {
    recordingUntil = null;
    notifyListeners();
  }

  Future<void> setTxPower(AdvertiseTxPower value) async {
    txPower = value;
    await _restartAdvertising();
  }

  void setLabel(String value) {
    label = value;
    notifyListeners();
  }

  void setMemo(String value) => memo = value;

  void setRecordSeconds(int value) {
    recordSeconds = value;
    notifyListeners();
  }

  void setBumpThreshold(double value) {
    bumpThreshold = value;
    notifyListeners();
  }

  void clear() {
    rows.clear();
    bumps.clear();
    notifyListeners();
  }

  // 거리·메모·송신세기·상대별로 묶은 기록 요약 - 현장에서 바로 경향을 보려는 용도
  List<SegmentStats> segmentStats() {
    final groups = <String, List<int>>{};
    for (final r in rows.where((r) => r.type == 'rssi')) {
      final memoPart = r.memo.isEmpty ? '' : ' / ${r.memo}';
      groups.putIfAbsent('${r.label}$memoPart / ${r.txPower} / ${r.peerId}', () => []).add(r.rssi!);
    }
    return groups.entries.map((e) => SegmentStats(e.key, e.value)).toList();
  }

  static const _saveChannel = MethodChannel('probe/save');

  // 앱 전용 폴더는 다른 앱에서 안 보여서, 내 파일 > 다운로드 > BLE실측 에 따로 저장
  Future<String> saveToDownloads() async {
    final name = 'rssi_${model.replaceAll(' ', '_')}_${myIdHex}_${_fileStamp(DateTime.now())}.csv';
    if (isIOS) {
      // iOS는 다운로드 폴더 개념이 없어서 문서 폴더에 저장 (파일 앱에서 보임)
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/$name').writeAsString(_csvContent());
      final shown = '파일 > 나의 iPhone > BLE 실측 > $name';
      rows.add(_row('saved', note: shown));
      return shown;
    }
    final path = await _saveChannel.invokeMethod<String>('saveToDownloads', {
      'name': name,
      'bytes': Uint8List.fromList(utf8.encode(_csvContent())),
    });
    rows.add(_row('saved', note: path ?? name));
    return path ?? name;
  }

  // 화면 꺼짐/켜짐·앱 전환 - 최신 안드로이드에서 화면 잠금 시 광고/스캔이 멈추는지 보려는 기록
  void logLifecycle(String state) {
    rows.add(_row('lifecycle', note: state));
    notifyListeners();
  }

  Future<File> exportCsv() async {
    final dir = await getTemporaryDirectory();
    final stamp = _fileStamp(DateTime.now());
    final file = File('${dir.path}/rssi_${model.replaceAll(' ', '_')}_${myIdHex}_$stamp.csv');
    await file.writeAsString(_csvContent());
    return file;
  }

  String _csvContent() {
    final buffer = StringBuffer('epoch_ms,time,type,my_id,my_model,sdk,tx_power,label,memo,peer_id,rssi,value,note\n');
    for (final r in rows) {
      buffer.writeln(
        [
          r.at.millisecondsSinceEpoch,
          formatTime(r.at),
          r.type,
          myIdHex,
          model,
          // 안드로이드는 예전 CSV와 같게 숫자만, iOS는 iOS18.1 형태
          isIOS ? osLabel : sdkInt,
          r.txPower,
          r.label,
          _csv(r.memo),
          r.peerId,
          r.rssi ?? '',
          r.value?.toStringAsFixed(1) ?? '',
          _csv(r.note),
        ].join(','),
      );
    }
    // 엑셀에서 한글이 안 깨지게 BOM을 붙임
    return '﻿$buffer';
  }

  @override
  void dispose() {
    _tick?.cancel();
    _watchdog?.cancel();
    _autosave?.cancel();
    _scanSub?.cancel();
    _accelSub?.cancel();
    _peripheral.stop();
    super.dispose();
  }
}

String formatTime(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';

String _fileStamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

String _two(int v) => v.toString().padLeft(2, '0');

String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

String _csv(String v) => v.contains(',') || v.contains('"') ? '"${v.replaceAll('"', '""')}"' : v;
