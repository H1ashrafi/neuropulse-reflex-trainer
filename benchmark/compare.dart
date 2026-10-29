import 'dart:io';
import 'dart:math' as math;

import 'package:neuropulse/models/session_result.dart';
import 'package:neuropulse/services/dri_engine.dart';
import 'package:neuropulse/services/reflex_ledger.dart';

abstract interface class SpreadEstimator {
  String get name;

  double? sampleStdDev(List<double> values);
}

final class NaiveSumOfSquares implements SpreadEstimator {
  const NaiveSumOfSquares();

  @override
  String get name => 'naive sum of squares';

  @override
  double? sampleStdDev(List<double> values) {
    if (values.length < 2) {
      return null;
    }
    var sum = 0.0;
    var sumOfSquares = 0.0;
    for (final value in values) {
      sum += value;
      sumOfSquares += value * value;
    }
    final count = values.length;
    final variance = (sumOfSquares - sum * sum / count) / (count - 1);
    return math.sqrt(math.max(0, variance));
  }
}

final class TwoPass implements SpreadEstimator {
  const TwoPass();

  @override
  String get name => 'two-pass textbook';

  @override
  double? sampleStdDev(List<double> values) {
    if (values.length < 2) {
      return null;
    }
    final mean = values.reduce((a, b) => a + b) / values.length;
    var squared = 0.0;
    for (final value in values) {
      squared += (value - mean) * (value - mean);
    }
    return math.sqrt(squared / (values.length - 1));
  }
}

final class WelfordStream implements SpreadEstimator {
  const WelfordStream();

  @override
  String get name => 'Welford (ours)';

  @override
  double? sampleStdDev(List<double> values) {
    final stats = RunningStats();
    for (final value in values) {
      stats.add(value);
    }
    return stats.sampleStdDev;
  }
}

final class Timing {
  const Timing(this.medianMicros, this.minMicros, this.maxMicros);

  static const int runs = 7;

  final double medianMicros;
  final double minMicros;
  final double maxMicros;

  static Timing of(void Function() body, {int repeat = 1}) {
    body();
    final samples = <double>[];
    for (var run = 0; run < runs; run += 1) {
      final watch = Stopwatch()..start();
      for (var index = 0; index < repeat; index += 1) {
        body();
      }
      samples.add(watch.elapsedMicroseconds / repeat);
    }
    samples.sort();
    return Timing(samples[runs ~/ 2], samples.first, samples.last);
  }

  @override
  String toString() =>
      '${medianMicros.toStringAsFixed(2)} µs (min ${minMicros.toStringAsFixed(2)}, max ${maxMicros.toStringAsFixed(2)})';
}

final class ExactSpread {
  static double of(List<int> offsets) {
    final count = BigInt.from(offsets.length);
    final sum = offsets.fold(BigInt.zero, (total, value) => total + BigInt.from(value));
    final squares = offsets.fold(BigInt.zero, (total, value) => total + BigInt.from(value) * BigInt.from(value));
    final numerator = count * squares - sum * sum;
    final denominator = count * (count - BigInt.one);
    return math.sqrt(numerator.toDouble() / denominator.toDouble());
  }
}

final class ClockProbe {
  const ClockProbe(this.name, this.read);

  static const int samples = 300000;

  final String name;
  final int Function() read;

  String measure() {
    var previous = read();
    var smallestStep = 1 << 62;
    var backwards = 0;
    for (var sample = 0; sample < samples; sample += 1) {
      final now = read();
      final step = now - previous;
      if (step < 0) {
        backwards += 1;
      } else if (step > 0 && step < smallestStep) {
        smallestStep = step;
      }
      previous = now;
    }
    return '| $name | $smallestStep µs | $backwards |';
  }
}

final class LedgerFixture {
  static ReflexLedger build(int sessions, DayKey today) {
    final random = math.Random(11);
    final made = <SessionResult>[];
    for (var index = 0; index < sessions; index += 1) {
      final day = today.shift(-(index % ReflexLedger.historyDays));
      final hits = 40 + random.nextInt(20);
      final reaction = ReactionSummary(
        trials: hits + 6,
        hits: hits,
        anticipationFaults: 2,
        misses: 3,
        correctRejections: 1,
        meanRtMs: 200 + random.nextDouble() * 120,
        stdDevMs: 20 + random.nextDouble() * 40,
      );
      final startedAt = DateTime.utc(day.year, day.month, day.day, 8, 0, 0, 0, index);
      made.add(SessionResult(
        id: SessionResult.idFor(startedAt, ProtocolMode.fullProtocol),
        mode: ProtocolMode.fullProtocol,
        startedAt: startedAt,
        dayKey: day,
        durationMs: 600000,
        dri: const DriCalculator().score(reaction),
        reaction: reaction,
        saccade: const SaccadeSummary(shown: 70, hits: 64, offTargetTaps: 3, meanAcquisitionMs: 512.4),
        burst: const BurstSummary(burstTaps: 240, cadenceTaps: 150, peakTapsPerSecond: 7.1, meanAsynchronyMs: 38.2),
      ));
    }
    return ReflexLedger(sessions: made, hallOfFame: made);
  }
}

void main() {
  const estimators = <SpreadEstimator>[NaiveSumOfSquares(), TwoPass(), WelfordStream()];
  final random = math.Random(3);
  final reactionOffsets = [for (var index = 0; index < 60; index += 1) 150 + random.nextInt(450)];
  final exact = ExactSpread.of(reactionOffsets);

  stdout.writeln('## Spread accuracy (n = 60 reaction times, exact SD = ${exact.toStringAsFixed(9)})\n');
  stdout.writeln('| estimator | error at 0 ms offset | error at 1e9 offset | error at 1e12 offset |');
  stdout.writeln('|---|---|---|---|');
  for (final estimator in estimators) {
    final errors = [
      for (final offset in [0.0, 1e9, 1e12])
        (estimator.sampleStdDev([for (final value in reactionOffsets) offset + value])! - exact).abs(),
    ];
    stdout.writeln('| ${estimator.name} | ${errors.map((e) => e.toStringAsExponential(2)).join(' | ')} |');
  }

  stdout.writeln('\n## Spread speed (median of ${Timing.runs} runs)\n');
  stdout.writeln('| estimator | n = 60 | n = 1,000,000 |');
  stdout.writeln('|---|---|---|');
  final small = [for (final value in reactionOffsets) value.toDouble()];
  final large = [for (var index = 0; index < 1000000; index += 1) 150 + random.nextDouble() * 450];
  for (final estimator in estimators) {
    final smallTiming = Timing.of(() => estimator.sampleStdDev(small), repeat: 20000);
    final largeTiming = Timing.of(() => estimator.sampleStdDev(large));
    stdout.writeln('| ${estimator.name} | $smallTiming | $largeTiming |');
  }

  stdout.writeln('\n## Clock resolution (${ClockProbe.samples} reads)\n');
  stdout.writeln('| clock | smallest step | backwards jumps |');
  stdout.writeln('|---|---|---|');
  final watch = Stopwatch()..start();
  stdout.writeln(ClockProbe('Stopwatch.elapsedMicroseconds (ours)', () => watch.elapsedMicroseconds).measure());
  stdout.writeln(ClockProbe('DateTime.now().microsecondsSinceEpoch', () => DateTime.now().microsecondsSinceEpoch).measure());
  stdout.writeln('\nStopwatch.frequency = ${Stopwatch().frequency} ticks/s');

  stdout.writeln('\n## Backup codec (median of ${Timing.runs} runs)\n');
  stdout.writeln('| sessions | JSON size | bytes/session | encode | decode + validate |');
  stdout.writeln('|---|---|---|---|---|');
  const codec = LedgerCodec();
  final today = DayKey.of(2026, 10, 27);
  for (final count in [30, 600, ReflexLedger.maxSessions]) {
    final ledger = LedgerFixture.build(count, today);
    final text = codec.encode(ledger);
    final encode = Timing.of(() => codec.encode(ledger));
    final decode = Timing.of(() => codec.decode(text));
    stdout.writeln('| $count | ${(text.length / 1024).toStringAsFixed(1)} KB | ${text.length ~/ count} | $encode | $decode |');
  }
}
