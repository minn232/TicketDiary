import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';

import '../models/preview_track.dart';
import 'app_settings_store.dart';
import 'concert_detail_service.dart';

/// 티켓을 열 때 iTunes 30초 미리듣기를 랜덤 재생(곡 사이는 크로스페이드).
/// 네트워크/재생 오류는 조용히 무시.
class TicketPreviewPlayer extends ChangeNotifier with WidgetsBindingObserver {
  TicketPreviewPlayer._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final TicketPreviewPlayer instance = TicketPreviewPlayer._();

  static const _fadeIn = Duration(milliseconds: 400);
  static const _fadeOut = Duration(milliseconds: 600);
  // 곡 전환 크로스페이드 시간
  static const _autoCrossfade = Duration(milliseconds: 2500);
  static const _skipCrossfade = Duration(milliseconds: 1200);
  static const _fadeStep = Duration(milliseconds: 40);

  final ConcertDetailService _service = ConcertDetailService();
  final Random _random = Random();
  final Map<String, List<PreviewTrack>> _tracksByTicket = {};
  final Map<String, Future<List<PreviewTrack>>> _loading = {};
  // 곡이 없던 티켓(prepare가 잠깐 건너뜀)
  final Map<String, DateTime> _emptyAt = {};
  static const _emptyRetry = Duration(minutes: 5);

  // 플레이어 둘을 번갈아 씀(재생 중인 쪽 / 다음 곡 로드 쪽)
  final List<AudioPlayer> _players = [];
  AudioPlayer? _active;
  // 플레이어별 볼륨 단계(0~1)와 페이드 세대
  final Map<AudioPlayer, double> _levels = {};
  final Map<AudioPlayer, int> _fadeGenerations = {};
  bool _sessionConfigured = false;

  // start/stop마다 증가 - 닫힌 뒤 늦게 온 응답 무시용
  int _token = 0;

  String? _ticketId;
  // 재생을 쓰는 오버레이들
  final Set<Object> _owners = {};
  PreviewTrack? _current;
  PreviewTrack? _last;
  // 최근 재생한 아티스트(오래된 순) - 같은 아티스트가 연달아 나오지 않게 하는 용도
  final List<String> _recentArtists = [];
  bool _crossfading = false;
  // 미리 로드해 둔 다음 곡
  PreviewTrack? _prepared;
  String? _preparedTicket;
  AudioPlayer? _preparedPlayer;
  Future<void>? _preparedLoad;
  bool _muted = false;
  // 백그라운드로 가서 멈춘 상태
  bool _backgrounded = false;
  List<AudioPlayer> _suspended = [];

  /// 재생 중인 곡(없으면 null).
  PreviewTrack? get current => _current;

  bool get muted => _muted;

  /// 오버레이가 열릴 때 재생 시작(예시 티켓/설정 꺼짐이면 무시).
  Future<void> start(String? ticketId, Object owner) async {
    if (ticketId == null || !AppSettingsStore.instance.playTicketPreview) {
      return;
    }
    // 같은 티켓의 오버레이가 겹쳐 열리면 재생을 이어감
    _owners.add(owner);
    if (_ticketId == ticketId && _current != null) return;
    final token = ++_token;
    _ticketId = ticketId;
    try {
      final tracks = await _tracksFor(ticketId);
      if (token != _token || tracks.isEmpty) return;
      if (await _isOtherAudioPlaying()) return;
      if (token != _token) return;
      final prepared = _preparedTicket == ticketId ? _prepared : null;
      await _play(prepared ?? _pick(tracks), token);
    } catch (_) {}
  }

  /// 티켓이 보일 때 곡 목록과 한 곡을 미리 받아둠.
  Future<void> prepare(String? ticketId) async {
    if (ticketId == null || !AppSettingsStore.instance.playTicketPreview) {
      return;
    }
    final emptyAt = _emptyAt[ticketId];
    if (emptyAt != null && DateTime.now().difference(emptyAt) < _emptyRetry) {
      return;
    }
    try {
      final tracks = await _tracksFor(ticketId);
      if (tracks.isEmpty) _emptyAt[ticketId] = DateTime.now();
      if (tracks.isEmpty || _prepared != null || _current != null) return;
      await _preload(_pick(tracks), ticketId);
    } catch (_) {
      _clearPrepared();
    }
  }

  // 쉬는 쪽 플레이어에 곡 로드
  Future<void> _preload(PreviewTrack track, String ticketId) async {
    final player = await _idlePlayer();
    _prepared = track;
    _preparedTicket = ticketId;
    _preparedPlayer = player;
    await _setLevel(player, 0);
    final load = player.setUrl(track.previewUrl);
    _preparedLoad = load;
    await load;
  }

  void _clearPrepared() {
    _prepared = null;
    _preparedTicket = null;
    _preparedPlayer = null;
    _preparedLoad = null;
  }

  // 곡 목록 조회(동시 요청은 합침, 빈 결과는 캐싱 안 함)
  Future<List<PreviewTrack>> _tracksFor(String ticketId) {
    final cached = _tracksByTicket[ticketId];
    if (cached != null) return Future.value(cached);
    return _loading[ticketId] ??= _loadQuickThenFull(
      ticketId,
    ).whenComplete(() => _loading.remove(ticketId));
  }

  // 빠른 조회(아티스트 2팀)로 바로 재생할 수 있게 하고, 전체 목록은 이어서 받아 교체
  Future<List<PreviewTrack>> _loadQuickThenFull(String ticketId) async {
    final quick = await _service.getPreviewTracks(ticketId, quick: true);
    if (quick.tracks.isNotEmpty) {
      _tracksByTicket[ticketId] = quick.tracks;
      unawaited(_loadFull(ticketId));
    }
    return quick.tracks;
  }

  Future<void> _loadFull(String ticketId) async {
    try {
      final full = await _service.getPreviewTracks(ticketId);
      if (full.tracks.isNotEmpty) _tracksByTicket[ticketId] = full.tracks;
    } catch (_) {}
  }

  // 앱이 뒤로 가면 멈추고 돌아오면 이어서 재생
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _suspend();
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_resume());
    }
  }

  void _suspend() {
    if (_backgrounded || _owners.isEmpty || _current == null) return;
    _backgrounded = true;
    // 진행 중인 페이드/전환 취소
    _token++;
    _suspended = _players.where((p) => p.playing).toList();
    for (final player in _suspended) {
      unawaited(player.pause());
    }
  }

  Future<void> _resume() async {
    if (!_backgrounded) return;
    _backgrounded = false;
    final suspended = _suspended;
    _suspended = [];
    if (_owners.isEmpty || _current == null) return;
    final token = ++_token;
    _crossfading = false;
    try {
      final active = _active;
      // 크로스페이드 중이던 앞 곡 정리
      for (final player in suspended.where((p) => p != active)) {
        await player.stop();
      }
      if (active == null || !suspended.contains(active)) {
        await playAnother(auto: true);
        return;
      }
      await _setLevel(active, 0);
      unawaited(active.play());
      await _fade(active, 1, _fadeIn, () => token != _token);
    } catch (_) {}
  }

  /// 오버레이가 닫힐 때 페이드아웃 후 정지.
  Future<void> stop(Object owner) async {
    // 겹친 오버레이 중 마지막이 닫힐 때만 멈춤
    if (!_owners.remove(owner) || _owners.isNotEmpty) return;
    final token = ++_token;
    final hadTrack = _current != null;
    _current = null;
    _crossfading = false;
    if (hadTrack) notifyListeners();
    // 크로스페이드 중이면 둘 다 줄임
    await Future.wait([
      for (final player in _players.where((p) => p.playing))
        _fadeAndStop(player, _fadeOut, () => token != _token),
    ]);
  }

  // 페이드가 끝까지 간 경우에만 정지
  Future<void> _fadeAndStop(
    AudioPlayer player,
    Duration duration,
    bool Function() cancelled,
  ) async {
    if (!await _fade(player, 0, duration, cancelled)) return;
    try {
      await player.stop();
    } catch (_) {}
  }

  /// 같은 티켓의 다른 곡으로 크로스페이드.
  Future<void> playAnother({bool auto = false}) async {
    final tracks = _tracksByTicket[_ticketId];
    if (tracks == null || tracks.isEmpty) return;
    final token = ++_token;
    try {
      final prepared = _preparedTicket == _ticketId ? _prepared : null;
      await _play(
        prepared ?? _pick(tracks),
        token,
        fadeIn: auto ? _autoCrossfade : _skipCrossfade,
      );
    } catch (_) {}
  }

  Future<void> toggleMute() async {
    _muted = !_muted;
    notifyListeners();
    for (final player in _players) {
      try {
        await player.setVolume(_muted ? 0 : (_levels[player] ?? 0));
      } catch (_) {}
    }
  }

  // 직전곡 제외 랜덤 - 아티스트가 여럿이면 최근에 나온 아티스트는 피해서 골고루 섞음
  PreviewTrack _pick(List<PreviewTrack> tracks) {
    final artistCount = tracks.map((t) => t.artistName).toSet().length;
    final avoidCount = min(artistCount - 1, 3);
    final avoid = avoidCount > 0
        ? _recentArtists.skip(max(0, _recentArtists.length - avoidCount)).toSet()
        : <String>{};
    var pool = tracks
        .where(
          (t) => !avoid.contains(t.artistName) && t.previewUrl != _last?.previewUrl,
        )
        .toList();
    if (pool.isEmpty) {
      pool = tracks.length > 1
          ? tracks.where((t) => t.previewUrl != _last?.previewUrl).toList()
          : tracks;
    }
    // 곡 수가 많은 아티스트로 쏠리지 않게 아티스트를 먼저 고른 뒤 그 곡 중 선택
    final artists = pool.map((t) => t.artistName).toSet().toList();
    final artist = artists[_random.nextInt(artists.length)];
    final ofArtist = pool.where((t) => t.artistName == artist).toList();
    return ofArtist[_random.nextInt(ofArtist.length)];
  }

  // 새 곡은 키우고 재생 중이던 곡은 줄임
  Future<void> _play(
    PreviewTrack track,
    int token, {
    Duration fadeIn = _fadeIn,
  }) async {
    final old = _active;
    final AudioPlayer player;
    if (identical(track, _prepared) && _preparedPlayer != null) {
      player = _preparedPlayer!;
      await _preparedLoad;
    } else {
      player = await _idlePlayer();
      await _setLevel(player, 0);
      await player.setUrl(track.previewUrl);
    }
    _clearPrepared();
    if (token != _token) return;
    _active = player;
    _current = track;
    _last = track;
    _recentArtists
      ..remove(track.artistName)
      ..add(track.artistName);
    _crossfading = false;
    notifyListeners();
    unawaited(player.play());
    // 앞 곡이 다 줄어든 뒤 다음 곡 미리 로드
    await Future.wait([
      _fade(player, 1, fadeIn, () => token != _token),
      if (old != null && old != player && old.playing)
        _fadeAndStop(old, fadeIn, () => token != _token),
    ]);
    final tracks = _tracksByTicket[_ticketId];
    final ticketId = _ticketId;
    if (token == _token && tracks != null && ticketId != null) {
      try {
        await _preload(_pick(tracks), ticketId);
      } catch (_) {
        _clearPrepared();
      }
    }
  }

  // 쉬는 쪽 플레이어(없으면 생성)
  Future<AudioPlayer> _idlePlayer() async {
    await _ensureSession();
    while (_players.length < 2) {
      final player = AudioPlayer();
      _players.add(player);
      _levels[player] = 0;
      player.playerStateStream.listen((state) {
        // 크로스페이드를 못 탄 경우의 안전장치
        if (state.processingState == ProcessingState.completed &&
            player == _active &&
            _current != null &&
            !_crossfading) {
          _crossfading = true;
          unawaited(playAnother(auto: true));
        }
      });
      // 곡이 끝나기 전에 다음 곡 시작
      player.positionStream.listen((position) {
        final duration = player.duration;
        if (player != _active ||
            _crossfading ||
            _current == null ||
            duration == null ||
            duration < _autoCrossfade * 2 ||
            duration - position > _autoCrossfade) {
          return;
        }
        _crossfading = true;
        unawaited(playAnother(auto: true));
      });
    }
    return _players.firstWhere((p) => p != _active, orElse: () => _players[0]);
  }

  Future<void> _ensureSession() async {
    if (_sessionConfigured) return;
    _sessionConfigured = true;
    try {
      // iOS는 ambient, 안드로이드는 미디어 볼륨
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.ambient,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
        ),
      );
    } catch (_) {}
  }

  Future<void> _setLevel(AudioPlayer player, double level) async {
    _levels[player] = level;
    _fadeGenerations[player] = (_fadeGenerations[player] ?? 0) + 1;
    await player.setVolume(_muted ? 0 : level);
  }

  // 다른 앱이 음악 재생 중인지 확인(우리 재생 중엔 건너뜀)
  Future<bool> _isOtherAudioPlaying() async {
    if (kIsWeb || _players.any((p) => p.playing)) return false;
    try {
      if (Platform.isIOS) return await AVAudioSession().isOtherAudioPlaying;
      if (Platform.isAndroid) {
        return await AndroidAudioManager().isMusicActive();
      }
    } catch (_) {}
    return false;
  }

  /// 끝까지 갔으면 true, 취소/대체됐으면 false.
  Future<bool> _fade(
    AudioPlayer player,
    double target,
    Duration duration,
    bool Function() cancelled,
  ) async {
    final generation = (_fadeGenerations[player] ?? 0) + 1;
    _fadeGenerations[player] = generation;
    final from = _levels[player] ?? 0;
    final steps = duration.inMilliseconds ~/ _fadeStep.inMilliseconds;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(_fadeStep);
      if (generation != _fadeGenerations[player] || cancelled()) return false;
      final level = from + (target - from) * i / steps;
      _levels[player] = level;
      try {
        await player.setVolume(_muted ? 0 : level);
      } catch (_) {
        return false;
      }
    }
    return true;
  }
}
