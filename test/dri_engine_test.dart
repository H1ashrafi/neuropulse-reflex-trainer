import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:neuropulse/models/session_result.dart';
import 'package:neuropulse/services/dri_engine.dart';

ReactionSummary summary({
  int trials = 40,
  int hits = 40,
  int faults = 0,
  int misses = 0,
  int rejections = 0,
  double? mean = 250,
  double? sd = 30,
}) =>
    ReactionSummary(
      trials: trials,
      hits: hits,
      anticipationFaults: faults,
      misses: misses,
      correctRejections: rejections,
      meanRtMs: mean,
      stdDevMs: sd,
    );

TrialRecord trial(PhaseKind phase, TrialOutcome outcome, [int? micros, CueKind cue = CueKind.go]) =>
    TrialRecord(phase: phase, cue: cue, outcome: outcome, reactionMicros: micros);

void main() {
  const calculator = DriCalculator();
  const classifier = ResponseClassifier();

  group('DriCalculator', () {
    test('applies every term of the published formula', () {
      final mixed = summary(trials: 40, hits: 34, faults: 4, misses: 2, mean: 250, sd: 30);
      final expected = 100 - (250 - 150) / 2.5 - 25 * (4 / 40) - 20 * (2 / 40) - 0.15 * 30;
      expect(calculator.score(mixed), closeTo(expected, 1e-12));
      expect(calculator.score(mixed), closeTo(52.0, 1e-12));
    });

    test('clamps to 100 when the mean beats the 150 ms baseline', () {
      expect(calculator.score(summary(mean: 120, sd: 0)), 100);
    });

    test('clamps to 0 when penalties exceed the scale', () {
      expect(calculator.score(summary(hits: 10, faults: 20, misses: 10, mean: 600, sd: 200)), 0);
    });

    test('scores zero when there are no valid hits because mean RT is undefined', () {
      expect(calculator.score(summary(hits: 0, misses: 40, mean: null, sd: null)), 0);
      expect(calculator.score(ReactionSummary.empty), 0);
    });

    test('treats an undefined spread from a single hit as zero spread', () {
      expect(calculator.score(summary(trials: 1, hits: 1, mean: 200, sd: null)), closeTo(80, 1e-12));
    });

    test('a faster mean always scores at least as high, all else equal', () {
      for (var mean = 100.0; mean < 600; mean += 7) {
        expect(calculator.score(summary(mean: mean)), greaterThanOrEqualTo(calculator.score(summary(mean: mean + 1))));
      }
    });
  });

  group('ResponseClassifier', () {
    test('99.999 ms is an anticipation fault because the limit is exclusive', () {
      expect(classifier.classifyTap(CueKind.go, 99999), TrialOutcome.anticipationFault);
    });

    test('exactly 100 ms is a valid hit', () {
      expect(classifier.classifyTap(CueKind.go, 100000), TrialOutcome.hit);
    });

    test('exactly 600 ms is still a hit and 600.001 ms is late', () {
      expect(classifier.classifyTap(CueKind.go, 600000), TrialOutcome.hit);
      expect(classifier.classifyTap(CueKind.go, 600001), TrialOutcome.lateResponse);
    });

    test('a sub-100 ms tap on no-go is anticipation, a slower one is a commission miss', () {
      expect(classifier.classifyTap(CueKind.noGo, 99999), TrialOutcome.anticipationFault);
      expect(classifier.classifyTap(CueKind.noGo, 100000), TrialOutcome.commissionError);
      expect(TrialOutcome.commissionError.isMiss, isTrue);
    });

    test('silence is a timeout on go and a correct rejection on no-go', () {
      expect(classifier.classifySilence(CueKind.go), TrialOutcome.timeout);
      expect(classifier.classifySilence(CueKind.noGo), TrialOutcome.correctRejection);
    });
  });

  group('RunningStats', () {
    test('matches the textbook sample standard deviation', () {
      final stats = RunningStats();
      for (var value = 1; value <= 10; value += 1) {
        stats.add(value.toDouble());
      }
      expect(stats.mean, 5.5);
      expect(stats.sampleStdDev, closeTo(3.0276503540974917, 1e-12));
    });

    test('stays exact under a huge common offset where the naive formula cancels', () {
      final stats = RunningStats();
      for (final value in [4.0, 7.0, 13.0, 16.0]) {
        stats.add(1e9 + value);
      }
      expect(stats.sampleStdDev, closeTo(math.sqrt(30), 1e-6));
    });

    test('reports no mean when empty and no spread below two samples', () {
      final stats = RunningStats();
      expect(stats.mean, isNull);
      stats.add(240);
      expect(stats.mean, 240);
      expect(stats.sampleStdDev, isNull);
    });
  });

  group('ReactionSummarizer', () {
    test('ignores warm-up and burst phases because only reaction phases are scored', () {
      final result = const ReactionSummarizer().summarize([
        trial(PhaseKind.saccade, TrialOutcome.hit, 900000),
        trial(PhaseKind.burstCadence, TrialOutcome.hit, 50000 + 100000),
        trial(PhaseKind.simpleReaction, TrialOutcome.hit, 200000),
        trial(PhaseKind.simpleReaction, TrialOutcome.hit, 300000),
      ]);
      expect(result.trials, 2);
      expect(result.meanRtMs, 250);
    });

    test('excludes anticipation faults from the mean but counts them in the rate', () {
      final result = const ReactionSummarizer().summarize([
        trial(PhaseKind.simpleReaction, TrialOutcome.hit, 240000),
        trial(PhaseKind.simpleReaction, TrialOutcome.hit, 260000),
        trial(PhaseKind.simpleReaction, TrialOutcome.anticipationFault, 40000),
        trial(PhaseKind.goNoGo, TrialOutcome.correctRejection, null, CueKind.noGo),
        trial(PhaseKind.goNoGo, TrialOutcome.commissionError, 300000, CueKind.noGo),
        trial(PhaseKind.goNoGo, TrialOutcome.timeout),
        trial(PhaseKind.goNoGo, TrialOutcome.lateResponse, 650000),
        trial(PhaseKind.simpleReaction, TrialOutcome.anticipationFault),
      ]);
      expect(result.trials, 8);
      expect(result.hits, 2);
      expect(result.meanRtMs, 250);
      expect(result.anticipationFaults, 2);
      expect(result.misses, 3);
      expect(result.correctRejections, 1);
      expect(result.falseStartRate, 0.25);
      expect(result.missRate, 3 / 8);
      expect(result.accuracy, 3 / 8);
    });

    test('a hit without a reaction time is refused at construction', () {
      expect(() => trial(PhaseKind.simpleReaction, TrialOutcome.hit), throwsArgumentError);
    });
  });

  group('ConsistencyGrade', () {
    test('maps spread onto S to D with inclusive upper bounds', () {
      expect(ConsistencyGrade.fromStdDev(null), isNull);
      expect(ConsistencyGrade.fromStdDev(25), ConsistencyGrade.s);
      expect(ConsistencyGrade.fromStdDev(25.01), ConsistencyGrade.a);
      expect(ConsistencyGrade.fromStdDev(55), ConsistencyGrade.b);
      expect(ConsistencyGrade.fromStdDev(75), ConsistencyGrade.c);
      expect(ConsistencyGrade.fromStdDev(400), ConsistencyGrade.d);
    });
  });
}
