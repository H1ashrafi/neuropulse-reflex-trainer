import 'package:flutter_test/flutter_test.dart';
import 'package:neuropulse/models/session_result.dart';
import 'package:neuropulse/services/timing_engine.dart';

import 'support/fakes.dart';

const Duration millisecond = Duration(milliseconds: 1);

void main() {
  group('state machine', () {
    test('walks IDLE → COUNTDOWN → JITTER_WAIT → ACTIVE_STIMULUS → RESPONSE_CAPTURED → INTERVAL_REST', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.simpleReaction, Duration(seconds: 30))]);
      expect(harness.engine.state, TrainingState.idle);
      harness.start();
      expect(harness.runUntilArmed(), isTrue);
      harness.clock.advance(const Duration(milliseconds: 250));
      harness.tap();
      harness.runUntil(() => harness.engine.state == TrainingState.jitterWait);
      expect(harness.states.take(6), [
        TrainingState.countdown,
        TrainingState.jitterWait,
        TrainingState.activeStimulus,
        TrainingState.responseCaptured,
        TrainingState.intervalRest,
        TrainingState.jitterWait,
      ]);
    });

    test('a full plan ends in SESSION_COMPLETE with a result and never runs past its budget', () {
      final harness = EngineHarness(const [
        PhaseSpec(PhaseKind.saccade, Duration(seconds: 12)),
        PhaseSpec(PhaseKind.simpleReaction, Duration(seconds: 25)),
        PhaseSpec(PhaseKind.goNoGo, Duration(seconds: 25)),
        PhaseSpec(PhaseKind.burstCadence, Duration(seconds: 20)),
      ]);
      harness.start();
      harness.runFor(const Duration(minutes: 3));
      final result = harness.engine.result;
      expect(harness.engine.state, TrainingState.sessionComplete);
      expect(result, isNotNull);
      expect(result!.durationMs, lessThanOrEqualTo(82000 + 17));
      expect(result.dayKey, DayKey.fromLocal(DateTime.utc(2026, 10, 27, 9)));
      expect(harness.cues.count('finished'), 1);
      expect(result.reaction.trials, greaterThan(0));
      expect(result.dri, 0);
    });

    test('abort discards the session and freezes the machine', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.simpleReaction, Duration(seconds: 30))]);
      harness.start();
      harness.runFor(const Duration(seconds: 5));
      harness.engine.abort();
      harness.runFor(const Duration(minutes: 1));
      expect(harness.engine.aborted, isTrue);
      expect(harness.engine.state, TrainingState.idle);
      expect(harness.engine.result, isNull);
      expect(harness.engine.protocolRemaining, Duration.zero);
    });

    test('an empty plan is rejected', () {
      expect(() => EngineHarness(const []), throwsArgumentError);
    });
  });

  group('reaction timing', () {
    test('latency is measured from the presented frame, not from the scheduled deadline', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.simpleReaction, Duration(seconds: 30))]);
      harness.start();
      harness.runUntil(() => harness.engine.state == TrainingState.jitterWait);
      harness.tickWithoutFramesUntil(() => harness.engine.state == TrainingState.activeStimulus);
      expect(harness.engine.stimulusArmed, isFalse);
      harness.clock.advance(const Duration(milliseconds: 40));
      harness.frames.present();
      expect(harness.engine.stimulusArmed, isTrue);
      harness.clock.advance(const Duration(microseconds: 213457));
      harness.tap();
      expect(harness.engine.lastFeedback!.outcome, TrialOutcome.hit);
      expect(harness.engine.lastFeedback!.reactionMicros, 213457);
    });

    test('foreperiods are continuous draws inside 1500–4500 ms', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.simpleReaction, Duration(minutes: 5))], seed: 99);
      harness.start();
      final foreperiods = <int>[];
      while (foreperiods.length < 40) {
        harness.runUntil(() => harness.engine.state == TrainingState.jitterWait, step: millisecond);
        final waitStarted = harness.clock.now;
        harness.runUntil(() => harness.engine.state == TrainingState.activeStimulus, step: millisecond);
        foreperiods.add(harness.clock.now - waitStarted);
      }
      expect(foreperiods.reduce((a, b) => a < b ? a : b), greaterThanOrEqualTo(1500000));
      expect(foreperiods.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(4501000));
      expect(foreperiods.toSet().length, greaterThan(35));
    });

    test('a tap during the foreperiod is an anticipation fault with no reaction time', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.simpleReaction, Duration(seconds: 30))]);
      harness.start();
      harness.runUntil(() => harness.engine.state == TrainingState.jitterWait);
      harness.tap();
      expect(harness.engine.state, TrainingState.responseCaptured);
      expect(harness.engine.trials.single.outcome, TrialOutcome.anticipationFault);
      expect(harness.engine.trials.single.reactionMicros, isNull);
    });

    test('a tap after the cue is scheduled but before it reaches the screen is a false start', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.simpleReaction, Duration(seconds: 30))]);
      harness.start();
      harness.tickWithoutFramesUntil(() => harness.engine.state == TrainingState.activeStimulus);
      harness.tap();
      harness.frames.present();
      expect(harness.engine.trials.single.outcome, TrialOutcome.anticipationFault);
      expect(harness.engine.stimulusArmed, isFalse);
      expect(harness.cues.count('present:go'), 0);
    });

    test('a tap at exactly 600 ms is a hit; silence beyond 600 ms is a timeout', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.simpleReaction, Duration(seconds: 40))]);
      harness.start();
      harness.runUntilArmed(step: millisecond);
      harness.clock.advance(const Duration(milliseconds: 600));
      harness.engine.tick();
      expect(harness.engine.state, TrainingState.activeStimulus);
      harness.tap();
      expect(harness.engine.trials.last.outcome, TrialOutcome.hit);
      harness.runUntilArmed(step: millisecond);
      harness.clock.advance(const Duration(microseconds: 600001));
      harness.engine.tick();
      expect(harness.engine.trials.last.outcome, TrialOutcome.timeout);
    });

    test('identical 250 ms responses score DRI 60 through the whole pipeline', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.simpleReaction, Duration(seconds: 40))]);
      harness.start();
      while (harness.runUntilArmed()) {
        harness.clock.advance(const Duration(milliseconds: 250));
        harness.tap();
      }
      harness.runFor(const Duration(minutes: 1));
      final result = harness.engine.result!;
      expect(result.reaction.hits, greaterThan(5));
      expect(result.reaction.meanRtMs, 250);
      expect(result.reaction.stdDevMs, 0);
      expect(result.dri, 60);
    });
  });

  group('go / no-go', () {
    test('withholding on no-go is a correct rejection; tapping it is a commission miss', () {
      final harness = EngineHarness(
        const [PhaseSpec(PhaseKind.goNoGo, Duration(seconds: 40))],
        timings: const EngineTimings(goProbability: 0),
      );
      harness.start();
      harness.runUntilArmed(step: millisecond);
      expect(harness.engine.cue, CueKind.noGo);
      harness.clock.advance(const Duration(milliseconds: 601));
      harness.engine.tick();
      expect(harness.engine.trials.last.outcome, TrialOutcome.correctRejection);
      harness.runUntilArmed(step: millisecond);
      harness.clock.advance(const Duration(milliseconds: 280));
      harness.tap();
      expect(harness.engine.trials.last.outcome, TrialOutcome.commissionError);
    });

    test('draws close to 70 percent go cues over 3000 trials', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.goNoGo, Duration(hours: 4))], seed: 2026);
      harness.start();
      while (harness.engine.trials.length < 3000) {
        harness.frame(const Duration(milliseconds: 50));
      }
      final goShare =
          harness.engine.trials.where((trial) => trial.cue == CueKind.go).length / harness.engine.trials.length;
      expect(goShare, inInclusiveRange(0.67, 0.73));
    });
  });

  group('saccades', () {
    test('off-target taps are counted without ending the trial; an on-target tap records acquisition', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.saccade, Duration(seconds: 20))]);
      harness.start();
      harness.runUntilArmed();
      final center = harness.targetCenter();
      final opposite = Offset(center.dx > 200 ? 0 : 400, center.dy > 400 ? 0 : 800);
      harness.clock.advance(const Duration(milliseconds: 120));
      harness.tapAt(opposite);
      expect(harness.engine.state, TrainingState.activeStimulus);
      harness.clock.advance(const Duration(milliseconds: 200));
      harness.tapAt(center);
      expect(harness.engine.state, TrainingState.responseCaptured);
      final summary = harness.engine.saccade.summary();
      expect(summary.hits, 1);
      expect(summary.offTargetTaps, 1);
      expect(summary.meanAcquisitionMs, 320);
    });

    test('each new target hops at least 0.3 of the screen from the last one', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.saccade, Duration(minutes: 2))], seed: 5);
      harness.start();
      Offset? previous;
      var hops = 0;
      while (hops < 60 && harness.runUntilArmed()) {
        final target = harness.engine.saccade.target;
        if (previous != null) {
          expect((target - previous).distance, greaterThanOrEqualTo(0.3 - 1e-9));
        }
        previous = target;
        hops += 1;
        harness.tapAt(harness.targetCenter());
      }
      expect(hops, 60);
    });

    test('an untouched target times out after 1.5 s and moves on', () {
      final harness = EngineHarness(const [PhaseSpec(PhaseKind.saccade, Duration(seconds: 20))]);
      harness.start();
      harness.runUntilArmed();
      harness.runFor(const Duration(milliseconds: 1550));
      expect(harness.engine.lastFeedback!.outcome, TrialOutcome.timeout);
      expect(harness.engine.saccade.summary().hits, 0);
    });
  });

  group('burst and cadence', () {
    test('rates the busiest burst block and measures distance to the beat', () {
      final harness = EngineHarness(
        const [PhaseSpec(PhaseKind.burstCadence, Duration(seconds: 33))],
        timings: const EngineTimings(countdown: Duration(seconds: 3)),
      );
      harness.start();
      harness.runUntil(() => harness.engine.state == TrainingState.activeStimulus);
      for (var tap = 0; tap < 60; tap += 1) {
        harness.clock.advance(const Duration(microseconds: 166000));
        harness.tap();
      }
      harness.runUntil(() => harness.engine.burst.segment == BurstSegment.cadence, step: millisecond);
      for (var beat = 0; beat < 10; beat += 1) {
        harness.runUntil(() => harness.cues.count('beat') > beat, step: millisecond);
        harness.clock.advance(const Duration(milliseconds: 30));
        harness.tap();
      }
      harness.runFor(const Duration(seconds: 30));
      final summary = harness.engine.result!.burst;
      expect(summary.burstTaps, 60);
      expect(summary.peakTapsPerSecond, closeTo(6.0, 0.01));
      expect(summary.cadenceTaps, 10);
      expect(summary.meanAsynchronyMs, closeTo(31, 1.01));
    });
  });
}
