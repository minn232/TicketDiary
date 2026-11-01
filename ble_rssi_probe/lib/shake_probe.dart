import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'probe.dart' show formatTime;
import 'shake_detector.dart';

// 흔들기 기준값 실측 - 여러 기준(세기)을 동시에 돌려 상황별로 몇 번 잡히는지 셈.
// 흔들기는 시도 대비 잡힌 비율, 나머지(걷기·주머니 등)는 잘못 잡힌 횟수를 봄
const shakeThresholds = [8.0, 10.0, 12.0, 15.0, 18.0];
const shakeScenarios = ['흔들기', '걷기', '뛰기', '주머니 넣고 빼기', '폰 맞대기', '책상에 놓기', '들고 화면 보기'];
// 시도 버튼을 누른 뒤 이 시간 안에 잡히면 성공
const _attemptWindow = Duration(seconds: 3);
// 기록 크기를 줄이려고 이보다 약한 표본은 CSV에 안 남김
const _sampleFloor = 8.0;

class ShakeRow {
  final DateTime at;
  final String type;
  final String scenario;
  final double? threshold;
  final double? x, y, z, mag;
  final String note;

  ShakeRow(this.at, this.type, this.scenario, {this.threshold, this.x, this.y, this.z, this.mag, this.note = ''});
}

class ScenarioStats {
  Duration recorded = Duration.zero;
  final fires = {for (final t in shakeThresholds) t: 0};
  int attempts = 0;
  final hits = {for (final t in shakeThresholds) t: 0};
}

class ShakeProbe extends ChangeNotifier {
  String model = '';
  String accelSource = '선형가속도';
  String scenario = shakeScenarios.first;
  bool recording = false;
  // 진동으로 알려줄 기준(본 앱 기본값)
  double hapticThreshold = 10;
  int requiredPeaks = 3;
  int windowMs = 800;

  final rows = <ShakeRow>[];
  final stats = {for (final s in shakeScenarios) s: ScenarioStats()};
  final recentFires = <ShakeRow>[];
  String? autosavePath;

  // 화면 표시용
  double lastMag = 0;
  double peak1s = 0;
  double sampleHz = 0;

  late Map<double, ShakeDetector> _detectors = _newDetectors();
  final _clock = Stopwatch()..start();
  StreamSubscription<dynamic>? _sub;
  Timer? _tick;
  Timer? _autosave;
  DateTime? _recordingSince;
  DateTime? _attemptUntil;
  final Set<double> _attemptHits = {};
  final _recentSamples = <(Duration, double)>[];
  int _savedRows = 0;
  String? _stamp;

  bool get attemptActive => _attemptUntil != null;
  bool get isIOS => !kIsWeb && Platform.isIOS;

  Map<double, ShakeDetector> _newDetectors() => {
    for (final t in shakeThresholds)
      t: ShakeDetector(threshold: t, requiredPeaks: requiredPeaks, window: Duration(milliseconds: windowMs)),
  };

  Future<void> init() async {
    if (isIOS) {
      model = (await DeviceInfoPlugin().iosInfo).modelName;
    } else {
      model = (await DeviceInfoPlugin().androidInfo).model;
    }
    _startAccel();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) => _onTick());
    _autosave = Timer.periodic(const Duration(seconds: 5), (_) => _autosaveCsv());
    notifyListeners();
  }

  // 선형가속도 센서가 없는 기기(A15)는 일반 가속도에서 중력을 추정해 뺌 - BLE 실측 화면과 같은 방식
  void _startAccel() {
    _sub = userAccelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
      (e) => _onAccel(e.x, e.y, e.z),
      onError: (Object _) {
        _sub?.cancel();
        accelSource = '가속도-중력추정';
        var gravity = [0.0, 0.0, 9.8];
        _sub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
          final raw = [e.x, e.y, e.z];
          gravity = [for (var i = 0; i < 3; i++) gravity[i] * 0.9 + raw[i] * 0.1];
          _onAccel(raw[0] - gravity[0], raw[1] - gravity[1], raw[2] - gravity[2]);
        });
        notifyListeners();
      },
      cancelOnError: true,
    );
  }

  void _onAccel(double x, double y, double z) {
    final at = _clock.elapsed;
    final now = DateTime.now();
    final mag = sqrt(x * x + y * y + z * z);
    lastMag = mag;
    _recentSamples
      ..add((at, mag))
      ..removeWhere((s) => at - s.$1 > const Duration(seconds: 1));
    if (!recording) return;
    if (mag >= _sampleFloor) rows.add(ShakeRow(now, 'sample', scenario, x: x, y: y, z: z, mag: mag));
    for (final entry in _detectors.entries) {
      if (!entry.value.add(x, y, z, at)) continue;
      final t = entry.key;
      stats[scenario]!.fires[t] = stats[scenario]!.fires[t]! + 1;
      final row = ShakeRow(now, 'fire', scenario, threshold: t, mag: mag);
      rows.add(row);
      recentFires.insert(0, row);
      if (recentFires.length > 30) recentFires.removeLast();
      if (attemptActive) _attemptHits.add(t);
      if (t == hapticThreshold) HapticFeedback.heavyImpact();
    }
  }

  void _onTick() {
    final now = DateTime.now();
    if (recording && _recordingSince != null) {
      stats[scenario]!.recorded += now.difference(_recordingSince!);
      _recordingSince = now;
    }
    if (_attemptUntil != null && now.isAfter(_attemptUntil!)) _finishAttempt();
    peak1s = _recentSamples.fold(0.0, (m, s) => max(m, s.$2));
    sampleHz = _recentSamples.length.toDouble();
    notifyListeners();
  }

  void setScenario(String value) {
    if (recording) _onTick();
    scenario = value;
    rows.add(ShakeRow(DateTime.now(), 'scenario', value));
    _resetDetectors();
    notifyListeners();
  }

  void setRecording(bool value) {
    if (!value) _onTick();
    recording = value;
    _recordingSince = value ? DateTime.now() : null;
    rows.add(ShakeRow(DateTime.now(), value ? 'start' : 'stop', scenario));
    _resetDetectors();
    notifyListeners();
  }

  // 흔들기 시도 - 누른 뒤 3초 안에 기준별로 잡혔는지 기록
  void startAttempt() {
    if (!recording) setRecording(true);
    _attemptHits.clear();
    _attemptUntil = DateTime.now().add(_attemptWindow);
    notifyListeners();
  }

  void _finishAttempt() {
    _attemptUntil = null;
    final s = stats[scenario]!;
    s.attempts++;
    for (final t in _attemptHits) {
      s.hits[t] = s.hits[t]! + 1;
    }
    final hitList = shakeThresholds.where(_attemptHits.contains).map((t) => t.toStringAsFixed(0)).join('/');
    rows.add(ShakeRow(DateTime.now(), 'attempt', scenario, note: hitList.isEmpty ? 'miss' : 'hit $hitList'));
  }

  void setHapticThreshold(double value) {
    hapticThreshold = value;
    notifyListeners();
  }

  void setRequiredPeaks(int value) {
    requiredPeaks = value;
    _detectors = _newDetectors();
    rows.add(ShakeRow(DateTime.now(), 'config', scenario, note: 'peaks=$value window=$windowMs'));
    notifyListeners();
  }

  void setWindowMs(int value) {
    windowMs = value;
    _detectors = _newDetectors();
    rows.add(ShakeRow(DateTime.now(), 'config', scenario, note: 'peaks=$requiredPeaks window=$value'));
    notifyListeners();
  }

  void _resetDetectors() {
    for (final d in _detectors.values) {
      d.reset();
    }
  }

  void clear() {
    rows.clear();
    recentFires.clear();
    for (final s in shakeScenarios) {
      stats[s] = ScenarioStats();
    }
    _savedRows = 0;
    _stamp = null;
    autosavePath = null;
    notifyListeners();
  }

  // BLE 실측과 같은 곳(/sdcard/Android/data/<패키지>/files)에 계속 덮어씀 - pull_csv.sh로 가져감
  Future<void> _autosaveCsv() async {
    if (rows.length == _savedRows) return;
    try {
      final dir = isIOS ? await getApplicationDocumentsDirectory() : await getExternalStorageDirectory();
      if (dir == null) return;
      _stamp ??= _fileStamp(DateTime.now());
      final file = File('${dir.path}/shake_${model.replaceAll(' ', '_')}_$_stamp.csv');
      await file.writeAsString(csvContent());
      _savedRows = rows.length;
      autosavePath = file.path;
    } catch (_) {}
  }

  Future<File> exportCsv() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/shake_${model.replaceAll(' ', '_')}_${_fileStamp(DateTime.now())}.csv');
    await file.writeAsString(csvContent());
    return file;
  }

  String csvContent() {
    final buffer = StringBuffer('epoch_ms,time,type,model,accel,scenario,threshold,x,y,z,mag,note\n');
    for (final r in rows) {
      buffer.writeln(
        [
          r.at.millisecondsSinceEpoch,
          formatTime(r.at),
          r.type,
          model,
          accelSource,
          r.scenario,
          r.threshold?.toStringAsFixed(0) ?? '',
          r.x?.toStringAsFixed(2) ?? '',
          r.y?.toStringAsFixed(2) ?? '',
          r.z?.toStringAsFixed(2) ?? '',
          r.mag?.toStringAsFixed(2) ?? '',
          r.note,
        ].join(','),
      );
    }
    // 엑셀에서 한글이 안 깨지게 BOM
    return '﻿$buffer';
  }

  @override
  void dispose() {
    _tick?.cancel();
    _autosave?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

String _fileStamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

String _two(int v) => v.toString().padLeft(2, '0');

class ShakeProbeScreen extends StatefulWidget {
  const ShakeProbeScreen({super.key});

  @override
  State<ShakeProbeScreen> createState() => _ShakeProbeScreenState();
}

class _ShakeProbeScreenState extends State<ShakeProbeScreen> {
  final probe = ShakeProbe();

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    probe.init();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    probe.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    final file = await probe.exportCsv();
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: '흔들기 실측 ${probe.model}'));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: probe,
      // 뒤로가기로 닫히면 기록이 사라져서 막음
      builder: (context, _) => PopScope(
        canPop: false,
        child: Scaffold(
          appBar: AppBar(
            title: Text('흔들기 실측 · ${probe.model}'),
            actions: [
              IconButton(onPressed: probe.rows.isEmpty ? null : _share, icon: const Icon(Icons.ios_share)),
              IconButton(onPressed: probe.clear, icon: const Icon(Icons.delete_outline)),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _live(),
              const Divider(height: 28),
              _controls(),
              const Divider(height: 28),
              _table(),
              const Divider(height: 28),
              _config(),
              const Divider(height: 28),
              const Text('최근 감지'),
              for (final r in probe.recentFires.take(15))
                Text(
                  '${formatTime(r.at)}  ${r.scenario}  기준 ${r.threshold!.toStringAsFixed(0)}  (${r.mag!.toStringAsFixed(1)})',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _live() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${probe.accelSource} · ${probe.sampleHz.toStringAsFixed(0)}Hz'),
        const SizedBox(height: 6),
        Text(
          '지금 ${probe.lastMag.toStringAsFixed(1)}  ·  최근 1초 최대 ${probe.peak1s.toStringAsFixed(1)} m/s²',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: (probe.peak1s / 40).clamp(0, 1), minHeight: 10),
        if (probe.autosavePath != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('자동 저장: ${probe.autosavePath}', style: const TextStyle(fontSize: 11)),
          ),
      ],
    );
  }

  Widget _controls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('상황'),
        Wrap(
          spacing: 8,
          children: [
            for (final s in shakeScenarios)
              ChoiceChip(label: Text(s), selected: probe.scenario == s, onSelected: (_) => probe.setScenario(s)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: () => probe.setRecording(!probe.recording),
              icon: Icon(probe.recording ? Icons.stop : Icons.fiber_manual_record),
              label: Text(probe.recording ? '기록 중지' : '기록 시작'),
            ),
            const SizedBox(width: 12),
            if (probe.scenario == '흔들기')
              OutlinedButton(
                onPressed: probe.attemptActive ? null : probe.startAttempt,
                child: Text(probe.attemptActive ? '3초 안에 흔드세요' : '흔들기 시도 +1'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          '흔들기: 시도 버튼 → 3초 안에 흔듦(성공률). 나머지: 기록 켜고 그 동작을 몇 분(잘못 잡힌 횟수)',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Widget _table() {
    String fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    const cell = TextStyle(fontFamily: 'monospace', fontSize: 12);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 14,
        headingRowHeight: 32,
        dataRowMinHeight: 28,
        dataRowMaxHeight: 32,
        columns: [
          const DataColumn(label: Text('상황')),
          const DataColumn(label: Text('시간/시도')),
          for (final t in shakeThresholds) DataColumn(label: Text(t.toStringAsFixed(0))),
        ],
        rows: [
          for (final s in shakeScenarios)
            DataRow(
              selected: probe.scenario == s,
              cells: [
                DataCell(Text(s, style: cell)),
                DataCell(
                  Text(
                    s == '흔들기' ? '${probe.stats[s]!.attempts}회' : fmt(probe.stats[s]!.recorded),
                    style: cell,
                  ),
                ),
                for (final t in shakeThresholds)
                  DataCell(
                    Text(
                      s == '흔들기'
                          ? '${probe.stats[s]!.hits[t]}/${probe.stats[s]!.attempts}'
                          : '${probe.stats[s]!.fires[t]}',
                      style: cell,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _config() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('진동으로 알려줄 기준'),
        Wrap(
          spacing: 8,
          children: [
            for (final t in shakeThresholds)
              ChoiceChip(
                label: Text(t.toStringAsFixed(0)),
                selected: probe.hapticThreshold == t,
                onSelected: (_) => probe.setHapticThreshold(t),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('필요한 흔들림 횟수 ${probe.requiredPeaks}회 (본 앱 3)'),
        Slider(
          min: 2,
          max: 5,
          divisions: 3,
          value: probe.requiredPeaks.toDouble(),
          onChanged: (v) => probe.setRequiredPeaks(v.round()),
        ),
        Text('모아야 하는 시간 ${probe.windowMs}ms (본 앱 800)'),
        Slider(
          min: 400,
          max: 1500,
          divisions: 11,
          value: probe.windowMs.toDouble(),
          onChanged: (v) => probe.setWindowMs(v.round()),
        ),
      ],
    );
  }
}
