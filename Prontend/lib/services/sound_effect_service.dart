import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

enum SoundEffect {
  bookSip,
  pageFlip,
  pageFlipBack,
  tabPages,
  splashPages,
  pageShift,
}

/// Small player boundary so cancellation during loading can be tested without
/// a device audio engine.
abstract interface class EffectAudioPlayer {
  Future<Duration?> load(String asset);
  Future<void> clip(Duration start, Duration end);
  Future<void> play();
  Future<void> stop();
  Future<void> dispose();
}

class _DeviceEffectPlayer implements EffectAudioPlayer {
  final _player = AudioPlayer();
  @override
  Future<Duration?> load(String asset) async {
    final duration = await _player.setAsset(asset);
    await _player.setSpeed(1);
    await _player.setVolume(1);
    return duration;
  }

  @override
  Future<void> clip(Duration start, Duration end) =>
      _player.setClip(start: start, end: end);
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> dispose() => _player.dispose();
}

class SoundEffectService {
  SoundEffectService({
    required EffectAudioPlayer Function() createPlayer,
    required Future<void> Function() prepareSession,
  }) : _createPlayer = createPlayer,
       _prepareSession = prepareSession;

  static final instance = SoundEffectService(
    createPlayer: _DeviceEffectPlayer.new,
    prepareSession: _configureSession,
  );
  final EffectAudioPlayer Function() _createPlayer;
  final Future<void> Function() _prepareSession;
  SoundPlayback? _active;
  Future<void> _silenceBarrier = Future.value();

  static const assets = <SoundEffect, String>{
    SoundEffect.bookSip: 'assets/audio/bookSip.wav',
    SoundEffect.pageFlip: 'assets/audio/bookPage.wav',
    SoundEffect.pageFlipBack: 'assets/audio/bookPageBack.wav',
    SoundEffect.tabPages: 'assets/audio/bookPages.wav',
    SoundEffect.splashPages: 'assets/audio/splash_pages_finish.wav',
    SoundEffect.pageShift: 'assets/audio/pageShift.wav',
  };

  SoundPlayback start(
    SoundEffect effect, {
    double from = 0,
    double to = 1,
    Duration startOffset = Duration.zero,
    Duration? maxDuration,
  }) {
    final previous = _active;
    previous?.stop();
    _silenceBarrier = Future.wait<void>([
      _silenceBarrier,
      if (previous != null) previous.released,
    ]).then((_) {});
    final playback = SoundPlayback._(_createPlayer());
    _active = playback;
    if (maxDuration != null) {
      playback._deadline = Timer(maxDuration, playback.stop);
    }
    unawaited(_run(effect, playback, _silenceBarrier, from, to, startOffset));
    return playback;
  }

  Future<void> _run(
    SoundEffect effect,
    SoundPlayback playback,
    Future<void> silence,
    double from,
    double to,
    Duration offset,
  ) async {
    try {
      // Wait for native stop to finish, including when the previous request was
      // still loading. Older requests can never restart after being replaced.
      await silence;
      if (playback.stopped) return;
      await _prepareSession();
      if (playback.stopped) return;
      final duration = await playback._player.load(assets[effect]!);
      if (playback.stopped || duration == null) return;
      final start =
          Duration(microseconds: (duration.inMicroseconds * from).round()) +
          offset;
      final end = Duration(
        microseconds: (duration.inMicroseconds * to).round(),
      );
      if (start >= end) return;
      await playback._player.clip(start, end);
      if (playback.stopped) return;
      await playback._player.play();
    } catch (error, stack) {
      if (!playback.stopped) {
        developer.log(
          '효과음 재생 실패: $effect',
          name: 'SoundEffectService',
          error: error,
          stackTrace: stack,
        );
      }
    } finally {
      playback.stop();
      if (identical(_active, playback)) _active = null;
    }
  }

  Future<void> play(SoundEffect effect) => start(effect).finished;

  static Future<void> _configureSession() async {
    final session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.mixWithOthers,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientMayDuck,
      ),
    );
    await session.setActive(true);
  }

  Future<void> dispose() async {
    final active = _active;
    _active = null;
    active?.stop();
    await _silenceBarrier;
    await active?.released;
  }
}

/// Each animation owns only its own handle; a stale completion cannot stop a
/// newer animation's sound.
class SoundPlayback {
  SoundPlayback._(this._player);
  final EffectAudioPlayer _player;
  final _finished = Completer<void>();
  Timer? _deadline;
  Future<void> _released = Future.value();
  Future<void> get finished => _finished.future;
  Future<void> get released => _released;
  bool stopped = false;

  void stop() {
    if (stopped) return;
    stopped = true;
    _deadline?.cancel();
    _released = _release();
    _finished.complete();
  }

  Future<void> _release() async {
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
