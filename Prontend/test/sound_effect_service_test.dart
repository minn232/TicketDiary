import 'dart:async';
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ticketdiary/services/sound_effect_service.dart';
import 'package:ticketdiary/services/ticket_transition_sound.dart';

class FakeEffectPlayer implements EffectAudioPlayer {
  Completer<Duration?>? loading;
  Completer<void>? stopping;
  final ended = Completer<void>();
  bool played = false, stopped = false, disposed = false;
  String? asset;
  @override
  Future<Duration?> load(String value) async {
    asset = value;
    return loading == null ? const Duration(seconds: 5) : loading!.future;
  }

  @override
  Future<void> clip(Duration start, Duration end) async {}
  @override
  Future<void> play() {
    played = true;
    return ended.future;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    if (stopping != null) await stopping!.future;
    if (!ended.isCompleted) ended.complete();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  testWidgets(
    'a newer effect immediately cancels an older effect that is still loading',
    (tester) async {
      final players = <FakeEffectPlayer>[];
      final pending = Completer<Duration?>();
      final service = SoundEffectService(
        createPlayer: () {
          final player = FakeEffectPlayer();
          if (players.isEmpty) player.loading = pending;
          players.add(player);
          return player;
        },
        prepareSession: () async {},
      );
      final first = service.start(SoundEffect.tabPages);
      await tester.pump();
      final next = service.start(SoundEffect.bookSip);
      expect(first.stopped, isTrue);
      await tester.pump();
      expect(players[1].played, isTrue);
      pending.complete(const Duration(seconds: 5));
      await tester.pump();
      expect(players[0].played, isFalse);
      expect(next.stopped, isFalse);
      await service.dispose();
    },
  );

  testWidgets(
    'rapid A B C requests wait for A native stop and cannot overlap',
    (tester) async {
      final players = <FakeEffectPlayer>[];
      final service = SoundEffectService(
        createPlayer: () {
          final p = FakeEffectPlayer();
          players.add(p);
          return p;
        },
        prepareSession: () async {},
      );
      service.start(SoundEffect.tabPages);
      await tester.pump();
      expect(players[0].played, isTrue);
      final release = Completer<void>();
      players[0].stopping = release;
      final second = service.start(SoundEffect.bookSip);
      service.start(SoundEffect.pageShift);
      await tester.pump();
      expect(players[0].stopped, isTrue);
      expect(second.stopped, isTrue);
      expect(players[1].played, isFalse);
      expect(players[2].played, isFalse);
      release.complete();
      await tester.pump();
      expect(players[2].played, isTrue);
      await service.dispose();
    },
  );

  testWidgets(
    'animation deadline stops a recording instead of changing its speed',
    (tester) async {
      final player = FakeEffectPlayer();
      final service = SoundEffectService(
        createPlayer: () => player,
        prepareSession: () async {},
      );
      final handle = service.start(
        SoundEffect.pageFlip,
        maxDuration: const Duration(milliseconds: 280),
      );
      await tester.pump();
      expect(player.played, isTrue);
      await tester.pump(const Duration(milliseconds: 279));
      expect(handle.stopped, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(handle.stopped, isTrue);
      await service.dispose();
    },
  );

  testWidgets(
    'ticket cue starts only when page or ticket becomes visible and ends with animation',
    (tester) async {
      final players = <FakeEffectPlayer>[];
      final service = SoundEffectService(
        createPlayer: () {
          final p = FakeEffectPlayer();
          players.add(p);
          return p;
        },
        prepareSession: () async {},
      );
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(milliseconds: 520),
      );
      final eased = CurvedAnimation(
        parent: controller,
        curve: Curves.easeInOutCubic,
      );
      final opacity = CurvedAnimation(
        parent: eased,
        curve: const Interval(.46, .54, curve: Curves.easeInOut),
      );
      final sync = TicketTransitionSound(
        controller: controller,
        pageOpacity: opacity,
        service: service,
      );
      controller.forward();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(players, isEmpty);
      await tester.pump(const Duration(milliseconds: 120));
      expect(players.length, 1);
      expect(players[0].played, isTrue);
      await tester.pump(const Duration(milliseconds: 266));
      expect(players[0].stopped, isTrue);
      controller.reverse();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(players.length, 1);
      await tester.pump(const Duration(milliseconds: 120));
      expect(players.length, 2);
      expect(players[1].played, isTrue);
      await tester.pump(const Duration(milliseconds: 266));
      expect(players[1].stopped, isTrue);
      sync.dispose();
      opacity.dispose();
      eased.dispose();
      controller.dispose();
      await service.dispose();
    },
  );
}
