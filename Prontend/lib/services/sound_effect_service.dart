import 'dart:async';
import 'dart:developer' as developer;
import 'audio_volume_store.dart';

import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';

enum SoundEffect {
  click,
  bookSip,
  pageFlip,
  pageFlipBack,
  calendar,
  tear,
  success,
  bookOpen,
  pageRustle,
  tabPages,
  splashPages,
  pageShift,
}

/// 앱에서 사용하는 짧은 UI 효과음을 한 곳에서 재생합니다.
class SoundEffectService {
  SoundEffectService._() {
    AudioVolumeStore.instance.addListener(() {
      for (final player in [..._players, ..._segments.map((p) => p.player)]) {
        unawaited(
          player
              .setVolume(AudioVolumeStore.instance.effects)
              .catchError((Object _) {}),
        );
      }
    });
  }
  final Set<SoundPlayback> _segments = {};

  static final instance = SoundEffectService._();

  final _players = List<AudioPlayer>.generate(3, (_) => AudioPlayer());
  var _nextPlayer = 0;
  var _requestId = 0;

  SoundPlayback start(
    SoundEffect effect, {
    double from = 0,
    double to = 1,
    Duration startOffset = Duration.zero,
    Duration? fitDuration,
    double speed = 1,
  }) {
    final playback = SoundPlayback();
    _segments.add(playback);
    final clock = Stopwatch()..start();
    final deadline = fitDuration == null
        ? null
        : Timer(fitDuration, playback.stop);
    unawaited(() async {
      try {
        await _ensureSession(++_requestId);
        if (playback.stopped) return;
        final duration = await playback.player.setAsset(_assets[effect]!);
        if (playback.stopped || duration == null) return;
        final begin = Duration(
          microseconds:
              (duration.inMicroseconds * from).round() +
              startOffset.inMicroseconds,
        );
        final end = Duration(
          microseconds: (duration.inMicroseconds * to).round(),
        );
        await playback.player.setClip(start: begin, end: end);
        if (playback.stopped) return;
        if (fitDuration != null) {
          final remaining =
              fitDuration.inMicroseconds - clock.elapsedMicroseconds;
          if (remaining <= 0) return;
          await playback.player.setSpeed(
            (end - begin).inMicroseconds / remaining,
          );
        } else {
          await playback.player.setSpeed(speed);
        }
        if (playback.stopped) return;
        await playback.player.setVolume(AudioVolumeStore.instance.effects);
        await playback.player.play();
      } catch (error) {
        _log(_requestId, 'SEGMENT_FAILED effect=$effect error=$error');
      } finally {
        deadline?.cancel();
        playback.stop();
        _segments.remove(playback);
      }
    }());
    return playback;
  }

  void _log(int id, String message) {
    // Release에서도 Flutter/Xcode 기기 콘솔에 남기는 임시 진단 로그.
    // ignore: avoid_print
    print('[SFX][$id][${DateTime.now().toIso8601String()}] $message');
  }

  static const _assets = <SoundEffect, String>{
    SoundEffect.pageShift: 'assets/sounds/pageShift.wav',
    SoundEffect.bookSip: 'assets/sounds/bookSip.wav',
    SoundEffect.click: 'assets/sounds/click.wav',
    SoundEffect.pageFlip: 'assets/sounds/bookPage.wav',
    SoundEffect.pageFlipBack: 'assets/sounds/bookPageBack.wav',
    SoundEffect.tabPages: 'assets/sounds/bookPages.wav',
    SoundEffect.splashPages: 'assets/sounds/splash_pages_finish.wav',
    SoundEffect.calendar: 'assets/sounds/calendar.wav',
    SoundEffect.tear: 'assets/sounds/tear.wav',
    SoundEffect.success: 'assets/sounds/success.wav',
    SoundEffect.bookOpen: 'assets/sounds/book_open.wav',
    SoundEffect.pageRustle: 'assets/sounds/page_rustle.wav',
  };

  Future<void> play(SoundEffect effect) async {
    final id = ++_requestId;
    final slot = _nextPlayer++ % _players.length;
    final player = _players[slot];
    final asset = _assets[effect]!;
    var stage = 'session';
    final timer = Stopwatch()..start();
    _log(id, 'REQUEST effect=${effect.name} player=$slot asset=$asset');
    final states = player.playerStateStream.listen((state) {
      _log(
        id,
        'STATE playing=${state.playing} processing=${state.processingState.name} '
        'positionMs=${player.position.inMilliseconds}',
      );
    });
    final errors = player.errorStream.listen((error) {
      _log(id, 'PLAYER_ERROR code=${error.code} message=${error.message}');
    });
    final pending = Timer(const Duration(seconds: 5), () {
      _log(id, 'WAITING stage=$stage elapsedMs=${timer.elapsedMilliseconds}');
    });
    try {
      await _ensureSession(id);
      stage = 'asset_load';
      _log(id, 'LOAD_BEGIN asset=$asset');
      final duration = await player.setAsset(asset);
      _log(id, 'LOAD_OK durationMs=${duration?.inMilliseconds}');
      stage = 'prepare';
      await player.setVolume(AudioVolumeStore.instance.effects);
      await player.seek(Duration.zero);
      stage = 'play';
      _log(id, 'PLAY_REQUEST volume=${player.volume}');
      await player.play();
      _log(
        id,
        'PLAY_RETURN processing=${player.processingState.name} '
        'positionMs=${player.position.inMilliseconds} elapsedMs=${timer.elapsedMilliseconds}',
      );
    } catch (error, stackTrace) {
      _log(
        id,
        'FAILED stage=$stage type=${error.runtimeType} error=$error\n$stackTrace',
      );
      developer.log(
        '효과음 재생 실패: $effect',
        name: 'SoundEffectService',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      pending.cancel();
      await states.cancel();
      await errors.cancel();
    }
  }

  Future<void> _ensureSession(int id) async {
    await AudioVolumeStore.instance.load();
    try {
      _log(id, 'SESSION_BEGIN');
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.mixWithOthers,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.sonification,
            usage: AndroidAudioUsage.assistanceSonification,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
        ),
      );
      _log(id, 'SESSION_CONFIGURED playback+mixWithOthers');
      final active = await session.setActive(true);
      _log(id, 'SESSION_ACTIVE result=$active');
      if (!active) {
        throw StateError('Audio session activation refused');
      }
    } catch (error, stackTrace) {
      developer.log(
        '오디오 세션 활성화 실패',
        name: 'SoundEffectService',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> dispose() async {
    for (final player in _players) {
      await player.dispose();
    }
  }
}

/// 각 애니메이션이 소유하며 로딩 중 취소도 처리하는 재생 핸들.
class SoundPlayback {
  final player = AudioPlayer();
  final _finished = Completer<void>();
  Future<void> get finished => _finished.future;
  bool stopped = false;

  void stop() {
    if (stopped) return;
    stopped = true;
    _finished.complete();
    unawaited(player.dispose());
  }
}
