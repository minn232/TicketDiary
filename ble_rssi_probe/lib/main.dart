import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'probe.dart';

void main() {
  runApp(const ProbeApp());
}

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE 실측',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ProbeScreen(),
    );
  }
}

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> with WidgetsBindingObserver {
  final probe = Probe();

  @override
  void initState() {
    super.initState();
    // 삼성은 화면이 꺼지면 스캔을 막아서 측정 중엔 화면을 켜둠
    WakelockPlus.enable();
    WidgetsBinding.instance.addObserver(this);
    probe.init();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    WidgetsBinding.instance.removeObserver(this);
    probe.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => probe.logLifecycle(state.name);

  Future<void> _saveToFiles() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await probe.saveToDownloads();
      messenger.showSnackBar(SnackBar(content: Text('저장됨: 내 파일 > $path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('저장 실패: $e')));
    }
  }

  Future<void> _share() async {
    final file = await probe.exportCsv();
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: 'BLE 실측 ${probe.model}'));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: probe,
      // 뒤로가기로 앱이 닫히면 메모리 기록이 사라져서 막음 (1차 측정 때 실제로 날아갈 뻔함)
      builder: (context, _) => PopScope(
        canPop: false,
        child: Scaffold(
          appBar: AppBar(
            title: Text('내 ID ${probe.myIdHex}'),
            actions: [
              IconButton(
                onPressed: probe.rows.isEmpty ? null : _saveToFiles,
                tooltip: '내 파일에 저장',
                icon: const Icon(Icons.save_alt),
              ),
              IconButton(onPressed: probe.rows.isEmpty ? null : _share, icon: const Icon(Icons.ios_share)),
              IconButton(onPressed: probe.clear, icon: const Icon(Icons.delete_outline)),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _status(),
              const SizedBox(height: 12),
              _holdSection(),
              const SizedBox(height: 12),
              _peers(),
              const Divider(height: 32),
              _recordControls(),
              const Divider(height: 32),
              _bumpSection(),
              const Divider(height: 32),
              _summary(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _status() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${probe.model} · SDK ${probe.sdkInt} · 광고 ${probe.advertising ? 'ON' : 'OFF'} · 스캔 ${probe.scanning ? 'ON' : 'OFF'} · ${probe.accelSource}',
        ),
        Text('스캔 재시작 ${probe.scanRestarts}회 · 광고 재시작 실패 ${probe.advRestartFailures}회'),
        if (probe.autosavePath != null) Text('자동 저장: ${probe.autosavePath}', style: const TextStyle(fontSize: 11)),
        if (probe.setupError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(probe.setupError!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final entry in txPowerNames.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: probe.txPower == entry.key,
                onSelected: (_) => probe.setTxPower(entry.key),
              ),
          ],
        ),
      ],
    );
  }

  Widget _holdSection() {
    final theme = Theme.of(context);
    final match = probe.lastMatch;
    final fresh = match != null && DateTime.now().difference(match.at) < const Duration(seconds: 4);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 56,
          child: probe.holdMode
              ? FilledButton(onPressed: () => probe.setHoldMode(false), child: const Text('맞대기 모드 ON (누르면 끔)'))
              : OutlinedButton(onPressed: () => probe.setHoldMode(true), child: const Text('맞대기 모드 켜기')),
        ),
        Text('연결 기준 1초 평균 ${probe.holdThreshold.toStringAsFixed(0)} dBm 이상'),
        Slider(min: -70, max: -40, divisions: 30, value: probe.holdThreshold, onChanged: probe.setHoldThreshold),
        if (probe.holdMode)
          Text(
            probe.holdLatched ? '연결 유지 중 - 폰을 떼야 다음 맞댐을 셈' : '대기 중 - 맞대고 기다리세요',
            style: TextStyle(color: probe.holdLatched ? theme.colorScheme.primary : null),
          ),
        if (match != null)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: fresh ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${probe.matchCount}회째 ${match.type == 'bump_match' ? '부딪힘 연결' : '연결됨'} · 상대 ${match.peerId} · ${match.rssi}dBm'
              '${match.type == 'hold_match' && match.value != null ? ' · 접근 후 ${match.value!.toStringAsFixed(0)}ms' : ''}'
              '\n${formatTime(match.at)}',
              style: fresh ? theme.textTheme.titleLarge : theme.textTheme.bodyMedium,
            ),
          ),
      ],
    );
  }

  Widget _peers() {
    final now = DateTime.now();
    if (probe.peers.isEmpty) {
      return const Text('상대 폰이 아직 안 보임 - 두 폰 모두 이 앱을 켜 두세요');
    }
    return Column(
      children: [
        for (final peer in probe.peers.values)
          Card(
            // 3대 동시·두 쌍 측정에서 누구와 연결됐는지 보이게 상대별로 상태 표시
            color: peer.holdMatched ? Theme.of(context).colorScheme.primaryContainer : null,
            child: ListTile(
              title: Text('상대 ${peer.id}${peer.holdMatched ? ' · 연결 유지 중' : ''}'),
              subtitle: Text(
                '초당 ${peer.packetsLastSecond(now)}개 · 마지막 ${peer.lastRssi ?? '-'} dBm\n'
                '상대 모드 ${peer.holdMode ? 'ON' : 'OFF'} · 연결 ${peer.matches}회',
              ),
              trailing: Text(
                peer.averageSince(now, const Duration(seconds: 1))?.toStringAsFixed(1) ?? '-',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
          ),
      ],
    );
  }

  Widget _recordControls() {
    final remaining = probe.recording ? probe.recordingUntil!.difference(DateTime.now()).inSeconds + 1 : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('거리'),
        Wrap(
          spacing: 8,
          children: [
            for (final l in distanceLabels)
              ChoiceChip(
                label: Text(l),
                selected: probe.label == l,
                onSelected: probe.recording ? null : (_) => probe.setLabel(l),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          enabled: !probe.recording,
          decoration: const InputDecoration(labelText: '메모 (예: 카페, 지하철, 주머니, 케이스O, 뒷면끼리)', isDense: true),
          onChanged: probe.setMemo,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('기록 시간'),
            const SizedBox(width: 8),
            for (final s in [10, 20, 30])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text('$s초'),
                  selected: probe.recordSeconds == s,
                  onSelected: probe.recording ? null : (_) => probe.setRecordSeconds(s),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: probe.recording
              ? FilledButton.tonal(onPressed: probe.stopRecording, child: Text('기록 중... $remaining초 (누르면 중지)'))
              : FilledButton(onPressed: probe.startRecording, child: Text('${probe.label} 기록 시작')),
        ),
      ],
    );
  }

  Widget _bumpSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('충격 감지 기준 ${probe.bumpThreshold.toStringAsFixed(0)} m/s²'),
        Slider(min: 5, max: 40, divisions: 35, value: probe.bumpThreshold, onChanged: probe.setBumpThreshold),
        const Text('bump=내 충격(가까운 상대·1초 평균 RSSI) / peer_bump=상대 충격 수신(내 충격과의 간격)'),
        const SizedBox(height: 4),
        for (final b in probe.bumps.take(12))
          Text(_bumpLine(b), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      ],
    );
  }

  String _bumpLine(ProbeRow b) => switch (b.type) {
    'bump' =>
      '${formatTime(b.at)}  내 충격 ${b.value!.toStringAsFixed(1)}  가까운 상대 ${b.peerId.isEmpty ? '-' : b.peerId} ${b.rssi ?? '-'}dBm',
    'hold_match' =>
      '${formatTime(b.at)}  ★ 연결됨 ${b.peerId} ${b.note}${b.value == null ? '' : ' 접근 후 ${b.value!.toStringAsFixed(0)}ms'}',
    'bump_match' => '${formatTime(b.at)}  ★ 부딪힘 연결 ${b.peerId} ${b.rssi}dBm',
    'recheck' => '${formatTime(b.at)}    └ 재확인 최대 ${b.value!.toStringAsFixed(1)} (${b.note})',
    _ =>
      '${formatTime(b.at)}  상대 ${b.peerId} 충격 수신 ${b.rssi}dBm  ${b.value == null ? '(내 충격 없음)' : '+${b.value!.toStringAsFixed(0)}ms'}',
  };

  Widget _summary() {
    final stats = probe.segmentStats();
    if (stats.isEmpty) return const Text('기록된 구간 없음');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('기록 요약 (총 ${probe.rows.length}행)'),
        const SizedBox(height: 4),
        for (final s in stats)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '${s.key}\n  n=${s.count}  평균 ${s.mean.toStringAsFixed(1)}  '
              'p10 ${s.percentile(0.1)}  중앙 ${s.percentile(0.5)}  p90 ${s.percentile(0.9)}  '
              '범위 ${s.percentile(0)}~${s.percentile(1)}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
      ],
    );
  }
}
