import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:neuropulse/models/session_result.dart';
import 'package:neuropulse/services/dri_engine.dart';
import 'package:neuropulse/services/storage_service.dart';
import 'package:neuropulse/services/timing_engine.dart';

final class FakeClock implements MonotonicClock {
  int now = 0;

  @override
  int get elapsedMicros => now;

  void advance(Duration step) => now += step.inMicroseconds;
}

final class ManualFrames implements FrameScheduler {
  final List<VoidCallback> _pending = [];

  int get pendingCount => _pending.length;

  @override
  void afterNextFrame(VoidCallback callback) => _pending.add(callback);

  void present() {
    final due = List.of(_pending);
    _pending.clear();
    for (final callback in due) {
      callback();
    }
  }
}

final class RecordingCues implements CueSink {
  final List<String> events = [];

  int count(String name) => events.where((event) => event == name).length;

  @override
  void phaseStarted(PhaseKind phase) => events.add('phase:${phase.name}');

  @override
  void countdownTick() => events.add('tick');

  @override
  void stimulusPresented(CueKind cue) => events.add('present:${cue.name}');

  @override
  void responseJudged(TrialOutcome outcome) => events.add('judged:${outcome.name}');

  @override
  void metronomeBeat() => events.add('beat');

  @override
  void sessionFinished() => events.add('finished');
}

final class EngineHarness {
  EngineHarness._(this.engine, this.clock, this.frames, this.cues) {
    engine.addListener(() {
      if (states.isEmpty || states.last != engine.state) {
        states.add(engine.state);
      }
    });
  }

  factory EngineHarness(
    List<PhaseSpec> phases, {
    int seed = 7,
    EngineTimings timings = const EngineTimings(),
    ProtocolMode mode = ProtocolMode.fullProtocol,
  }) {
    final clock = FakeClock();
    final frames = ManualFrames();
    final cues = RecordingCues();
    final engine = TimingEngine(
      plan: ProtocolPlan(mode, phases),
      clock: clock,
      frames: frames,
      cues: cues,
      random: math.Random(seed),
      timings: timings,
    );
    return EngineHarness._(engine, clock, frames, cues);
  }

  static const Duration frameInterval = Duration(microseconds: 16667);
  static const Size screen = Size(400, 800);

  final TimingEngine engine;
  final FakeClock clock;
  final ManualFrames frames;
  final RecordingCues cues;
  final List<TrainingState> states = [];

  void start() => engine.start(DateTime.utc(2026, 10, 27, 9));

  void frame([Duration step = frameInterval]) {
    clock.advance(step);
    engine.tick();
    frames.present();
  }

  void runFor(Duration span, {Duration step = frameInterval}) {
    final until = clock.now + span.inMicroseconds;
    while (clock.now < until && engine.state != TrainingState.sessionComplete) {
      frame(step);
    }
  }

  bool runUntil(
    bool Function() condition, {
    Duration step = frameInterval,
    Duration limit = const Duration(minutes: 30),
  }) {
    final until = clock.now + limit.inMicroseconds;
    while (!condition()) {
      if (clock.now >= until || engine.state == TrainingState.sessionComplete) {
        return false;
      }
      frame(step);
    }
    return true;
  }

  void tickWithoutFramesUntil(bool Function() condition, {Duration step = const Duration(milliseconds: 1)}) {
    while (!condition()) {
      clock.advance(step);
      engine.tick();
    }
  }

  bool runUntilArmed({Duration step = frameInterval}) => runUntil(
        () => engine.state == TrainingState.activeStimulus && engine.stimulusArmed,
        step: step,
      );

  void tapAt(Offset position) => engine.onPointerDown(position, screen);

  void tap() => tapAt(screen.center(Offset.zero));

  Offset targetCenter() {
    final target = engine.saccade.target;
    return Offset(target.dx * screen.width, target.dy * screen.height);
  }
}

abstract final class SessionFactory {
  static int _serial = 0;

  static ReactionSummary reactionFor(double dri) => ReactionSummary(
        trials: 10,
        hits: 10,
        anticipationFaults: 0,
        misses: 0,
        correctRejections: 0,
        meanRtMs: DriCalculator.baselineRtMs + DriCalculator.rtMsPerPoint * (100 - dri),
        stdDevMs: 0,
      );

  static SessionResult make({
    required DayKey day,
    required double dri,
    ProtocolMode mode = ProtocolMode.fullProtocol,
    int hour = 9,
    String? id,
  }) {
    _serial += 1;
    final reaction = reactionFor(dri);
    final startedAt = DateTime.utc(day.year, day.month, day.day, hour, 0, 0, 0, _serial);
    return SessionResult(
      id: id ?? SessionResult.idFor(startedAt, mode),
      mode: mode,
      startedAt: startedAt,
      dayKey: day,
      durationMs: 600000,
      dri: const DriCalculator().score(reaction),
      reaction: reaction,
      saccade: SaccadeSummary.empty,
      burst: BurstSummary.empty,
    );
  }
}

final class FailingStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => throw const FormatException('disk unplugged');

  @override
  Future<void> write(String key, String value) async =>
      throw const FormatException('disk unplugged');
}

final class SlowStore implements KeyValueStore {
  SlowStore(this.delays);

  final List<Duration> delays;
  final Map<String, String> values = {};
  int _writes = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    final delay = delays[_writes % delays.length];
    _writes += 1;
    await Future<void>.delayed(delay);
    values[key] = value;
  }
}
