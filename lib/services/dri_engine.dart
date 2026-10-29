import 'dart:math' as math;

import '../models/session_result.dart';

final class RunningStats {
  int _count = 0;
  double _mean = 0;
  double _sumOfSquaredDeviations = 0;

  int get count => _count;

  double? get mean => _count == 0 ? null : _mean;

  double? get sampleStdDev =>
      _count < 2 ? null : math.sqrt(_sumOfSquaredDeviations / (_count - 1));

  void add(double value) {
    _count += 1;
    final deviationBefore = value - _mean;
    _mean += deviationBefore / _count;
    _sumOfSquaredDeviations += deviationBefore * (value - _mean);
  }
}

abstract final class ReactionWindow {
  static const int anticipationLimitMicros = 100000;
  static const int timeoutMicros = 600000;
  static const double microsPerMilli = 1000;
}

final class ResponseClassifier {
  const ResponseClassifier();

  TrialOutcome classifyTap(CueKind cue, int reactionMicros) {
    if (reactionMicros < ReactionWindow.anticipationLimitMicros) {
      return TrialOutcome.anticipationFault;
    }
    if (cue == CueKind.noGo) {
      return TrialOutcome.commissionError;
    }
    if (reactionMicros > ReactionWindow.timeoutMicros) {
      return TrialOutcome.lateResponse;
    }
    return TrialOutcome.hit;
  }

  TrialOutcome classifySilence(CueKind cue) =>
      cue == CueKind.go ? TrialOutcome.timeout : TrialOutcome.correctRejection;
}

final class ReactionSummarizer {
  const ReactionSummarizer();

  ReactionSummary summarize(Iterable<TrialRecord> trials) {
    final hitTimes = RunningStats();
    var scored = 0;
    var faults = 0;
    var misses = 0;
    var rejections = 0;
    for (final trial in trials.where((trial) => trial.phase.isScored)) {
      scored += 1;
      switch (trial.outcome) {
        case TrialOutcome.hit:
          hitTimes.add(trial.reactionMicros! / ReactionWindow.microsPerMilli);
        case TrialOutcome.anticipationFault:
          faults += 1;
        case TrialOutcome.correctRejection:
          rejections += 1;
        case TrialOutcome.lateResponse || TrialOutcome.timeout || TrialOutcome.commissionError:
          misses += 1;
      }
    }
    return ReactionSummary(
      trials: scored,
      hits: hitTimes.count,
      anticipationFaults: faults,
      misses: misses,
      correctRejections: rejections,
      meanRtMs: hitTimes.mean,
      stdDevMs: hitTimes.sampleStdDev,
    );
  }
}

final class DriCalculator {
  const DriCalculator();

  static const double perfectScore = 100;
  static const double baselineRtMs = 150;
  static const double rtMsPerPoint = 2.5;
  static const double falseStartWeight = 25;
  static const double missWeight = 20;
  static const double stdDevWeight = 0.15;
  static const double floor = 0;
  static const double ceiling = 100;

  double score(ReactionSummary summary) {
    final meanRtMs = summary.meanRtMs;
    if (summary.trials == 0 || meanRtMs == null) {
      return floor;
    }
    final speedPenalty = (meanRtMs - baselineRtMs) / rtMsPerPoint;
    final falseStartPenalty = falseStartWeight * summary.falseStartRate;
    final missPenalty = missWeight * summary.missRate;
    final spreadPenalty = stdDevWeight * (summary.stdDevMs ?? 0);
    final raw = perfectScore - speedPenalty - falseStartPenalty - missPenalty - spreadPenalty;
    return raw.clamp(floor, ceiling).toDouble();
  }
}
