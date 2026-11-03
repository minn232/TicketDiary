import 'dart:async';
import 'package:flutter/material.dart';

import '../services/audio_volume_store.dart';
import 'paper_style.dart';
import 'responsive_text.dart';

/// 효과음과 공연 노래 미리듣기의 앱 내 볼륨을 개별 조절합니다.
class AudioVolumeSettings extends StatefulWidget {
  const AudioVolumeSettings({super.key});

  @override
  State<AudioVolumeSettings> createState() => _AudioVolumeSettingsState();
}

class _AudioVolumeSettingsState extends State<AudioVolumeSettings> {
  final _store = AudioVolumeStore.instance;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await _store.load();
    if (mounted) setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) => Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: PaperColors.tile,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: PaperColors.muted.withValues(alpha: .18)),
      ),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: PaperColors.muted,
          inactiveTrackColor: PaperColors.muted.withValues(alpha: .2),
          thumbColor: PaperColors.ink,
          overlayColor: PaperColors.muted.withValues(alpha: .12),
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bar('효과음', _store.effects, isMusic: false),
            Divider(color: PaperColors.muted.withValues(alpha: .18)),
            _bar('노래 미리듣기', _store.music, isMusic: true),
            Text(
              '공연 후 페이지의 미리듣기 음량을 조절해요',
              style: TextStyle(
                fontSize: context.sp(11),
                height: 1.4,
                color: PaperColors.muted,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _bar(String title, double value, {required bool isMusic}) => Column(
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: context.sp(13),
                fontWeight: FontWeight.w700,
                color: PaperColors.ink,
              ),
            ),
          ),
          Text(
            '${(value * 100).round()}%',
            style: TextStyle(
              fontSize: context.sp(12),
              color: PaperColors.muted,
            ),
          ),
        ],
      ),
      Semantics(
        label: title,
        child: Slider(
          key: ValueKey(isMusic ? 'music-volume' : 'effects-volume'),
          value: value,
          semanticFormatterCallback: (value) => '${(value * 100).round()}%',
          onChanged: _loaded
              ? (value) {
                  unawaited(_store.setVolume(value, isMusic: isMusic));
                }
              : null,
        ),
      ),
    ],
  );
}
