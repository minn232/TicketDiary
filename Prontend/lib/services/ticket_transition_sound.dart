import 'package:flutter/animation.dart';

import 'sound_effect_service.dart';

/// Synchronizes the cue with the same opacity that reveals the page/ticket,
/// rather than with the earlier tap or a device-dependent wall-clock delay.
class TicketTransitionSound {
  TicketTransitionSound({
    required this.controller,
    required this.pageOpacity,
    SoundEffectService? service,
  }) : _service = service ?? SoundEffectService.instance {
    controller.addStatusListener(_statusChanged);
    pageOpacity.addListener(_visibilityChanged);
  }

  final AnimationController controller;
  final Animation<double> pageOpacity;
  final SoundEffectService _service;
  SoundPlayback? _playback;
  bool _played = false;

  void _statusChanged(AnimationStatus status) {
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      _played = false;
      _visibilityChanged();
    } else {
      _playback?.stop();
    }
  }

  void _visibilityChanged() {
    if (_played) return;
    final visible = switch (controller.status) {
      AnimationStatus.forward => pageOpacity.value > 0,
      AnimationStatus.reverse => pageOpacity.value < 1,
      _ => false,
    };
    if (!visible) return;
    _played = true;
    _playback = _service.start(SoundEffect.bookSip);
  }

  void dispose() {
    controller.removeStatusListener(_statusChanged);
    pageOpacity.removeListener(_visibilityChanged);
    _playback?.stop();
  }
}
