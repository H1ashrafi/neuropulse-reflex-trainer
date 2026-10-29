import 'json_guard.dart';

enum ProtocolMode {
  fullProtocol('full', 'Full protocol', ranked: true),
  quickProtocol('quick', 'Quick 4-phase', ranked: false),
  simpleReaction('srt', 'SRT module', ranked: false),
  goNoGo('gng', 'Go / No-Go module', ranked: false);

  const ProtocolMode(this.code, this.label, {required this.ranked});

  final String code;
  final String label;
  final bool ranked;

  static ProtocolMode? fromCode(String code) =>
      values.where((mode) => mode.code == code).firstOrNull;
}

enum PhaseKind {
  saccade('Visual saccades', 'Tap each target the moment it lands.'),
  simpleReaction('Simple reaction', 'Rest on the cross. Tap the instant the screen turns green.'),
  goNoGo('Go / No-Go', 'Green: tap. Red: hold perfectly still.'),
  burstCadence('Burst & cadence', 'Burst: tap as fast as you can. Cadence: tap on every beat.');

  const PhaseKind(this.title, this.instruction);

  final String title;
  final String instruction;

  bool get isScored => this == simpleReaction || this == goNoGo;
}

enum CueKind { go, noGo }

enum TrialOutcome {
  hit,
  anticipationFault,
  lateResponse,
  timeout,
  correctRejection,
  commissionError;

  bool get isMiss => switch (this) {
        lateResponse || timeout || commissionError => true,
        hit || anticipationFault || correctRejection => false,
      };

  bool get isCorrect => this == hit || this == correctRejection;
}

enum ConsistencyGrade {
  s(25),
  a(40),
  b(55),
  c(75),
  d(double.infinity);

  const ConsistencyGrade(this.maxStdDevMs);

  final double maxStdDevMs;

  String get label => name.toUpperCase();

  static ConsistencyGrade? fromStdDev(double? stdDevMs) {
    if (stdDevMs == null) {
      return null;
    }
    return values.firstWhere((grade) => stdDevMs <= grade.maxStdDevMs);
  }
}

final class DayKey implements Comparable<DayKey> {
  const DayKey._(this.year, this.month, this.day);

  factory DayKey.fromLocal(DateTime moment) {
    final local = moment.toLocal();
    return DayKey._(local.year, local.month, local.day);
  }

  factory DayKey.of(int year, int month, int day) {
    final normalized = DateTime.utc(year, month, day);
    if (normalized.year != year || normalized.month != month || normalized.day != day) {
      throw DataFormatException('$year-$month-$day is not a calendar day');
    }
    return DayKey._(year, month, day);
  }

  factory DayKey.parse(String text) {
    final match = _pattern.firstMatch(text);
    if (match == null) {
      throw DataFormatException('day must look like YYYY-MM-DD');
    }
    return DayKey.of(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
  }

  static final RegExp _pattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
  static const int _millisPerDay = Duration.millisecondsPerDay;

  final int year;
  final int month;
  final int day;

  DateTime get _utcMidnight => DateTime.utc(year, month, day);

  int get epochDay => _utcMidnight.millisecondsSinceEpoch ~/ _millisPerDay;

  DayKey shift(int days) {
    final moved = DateTime.utc(year, month, day + days);
    return DayKey._(moved.year, moved.month, moved.day);
  }

  int daysSince(DayKey earlier) => epochDay - earlier.epochDay;

  @override
  int compareTo(DayKey other) => epochDay.compareTo(other.epochDay);

  @override
  bool operator ==(Object other) =>
      other is DayKey && other.year == year && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}

final class TrialRecord {
  TrialRecord({
    required this.phase,
    required this.cue,
    required this.outcome,
    required this.reactionMicros,
  }) {
    if (outcome == TrialOutcome.hit && reactionMicros == null) {
      throw ArgumentError.value(reactionMicros, 'reactionMicros', 'a hit needs a reaction time');
    }
  }

  final PhaseKind phase;
  final CueKind cue;
  final TrialOutcome outcome;
  final int? reactionMicros;
}

abstract final class MetricLimits {
  static const int maxCount = 100000;
  static const double minValidRtMs = 100;
  static const double maxValidRtMs = 600;
  static const double maxStdDevMs = 500;
  static const double maxAcquisitionMs = 5000;
  static const double maxTapsPerSecond = 100;
  static const double maxAsynchronyMs = 5000;
  static const int maxDurationMs = 3600000;
}

final class ReactionSummary {
  const ReactionSummary({
    required this.trials,
    required this.hits,
    required this.anticipationFaults,
    required this.misses,
    required this.correctRejections,
    required this.meanRtMs,
    required this.stdDevMs,
  });

  factory ReactionSummary.fromJson(JsonGuard json) {
    int count(String key) => json.integer(key, min: 0, max: MetricLimits.maxCount);
    final summary = ReactionSummary(
      trials: count('trials'),
      hits: count('hits'),
      anticipationFaults: count('faults'),
      misses: count('misses'),
      correctRejections: count('correctRejections'),
      meanRtMs: json.optionalNumber('meanRtMs',
          min: MetricLimits.minValidRtMs, max: MetricLimits.maxValidRtMs),
      stdDevMs: json.optionalNumber('stdDevMs', min: 0, max: MetricLimits.maxStdDevMs),
    );
    final outcomesAddUp = summary.hits +
            summary.anticipationFaults +
            summary.misses +
            summary.correctRejections ==
        summary.trials;
    final meanMatchesHits = (summary.meanRtMs == null) == (summary.hits == 0);
    final spreadMatchesHits = (summary.stdDevMs == null) == (summary.hits < 2);
    if (!outcomesAddUp || !meanMatchesHits || !spreadMatchesHits) {
      throw DataFormatException('${json.path} has counts that do not add up');
    }
    return summary;
  }

  static const ReactionSummary empty = ReactionSummary(
    trials: 0,
    hits: 0,
    anticipationFaults: 0,
    misses: 0,
    correctRejections: 0,
    meanRtMs: null,
    stdDevMs: null,
  );

  final int trials;
  final int hits;
  final int anticipationFaults;
  final int misses;
  final int correctRejections;
  final double? meanRtMs;
  final double? stdDevMs;

  double _share(int count) => trials == 0 ? 0 : count / trials;

  double get falseStartRate => _share(anticipationFaults);

  double get missRate => _share(misses);

  double get accuracy => _share(hits + correctRejections);

  Map<String, Object?> toJson() => {
        'trials': trials,
        'hits': hits,
        'faults': anticipationFaults,
        'misses': misses,
        'correctRejections': correctRejections,
        'meanRtMs': meanRtMs,
        'stdDevMs': stdDevMs,
      };
}

final class SaccadeSummary {
  const SaccadeSummary({
    required this.shown,
    required this.hits,
    required this.offTargetTaps,
    required this.meanAcquisitionMs,
  });

  factory SaccadeSummary.fromJson(JsonGuard json) {
    final shown = json.integer('shown', min: 0, max: MetricLimits.maxCount);
    final summary = SaccadeSummary(
      shown: shown,
      hits: json.integer('hits', min: 0, max: shown),
      offTargetTaps: json.integer('offTarget', min: 0, max: MetricLimits.maxCount),
      meanAcquisitionMs:
          json.optionalNumber('meanAcquisitionMs', min: 0, max: MetricLimits.maxAcquisitionMs),
    );
    if ((summary.meanAcquisitionMs == null) != (summary.hits == 0)) {
      throw DataFormatException('${json.path} has counts that do not add up');
    }
    return summary;
  }

  static const SaccadeSummary empty =
      SaccadeSummary(shown: 0, hits: 0, offTargetTaps: 0, meanAcquisitionMs: null);

  final int shown;
  final int hits;
  final int offTargetTaps;
  final double? meanAcquisitionMs;

  Map<String, Object?> toJson() => {
        'shown': shown,
        'hits': hits,
        'offTarget': offTargetTaps,
        'meanAcquisitionMs': meanAcquisitionMs,
      };
}

final class BurstSummary {
  const BurstSummary({
    required this.burstTaps,
    required this.cadenceTaps,
    required this.peakTapsPerSecond,
    required this.meanAsynchronyMs,
  });

  factory BurstSummary.fromJson(JsonGuard json) => BurstSummary(
        burstTaps: json.integer('burstTaps', min: 0, max: MetricLimits.maxCount),
        cadenceTaps: json.integer('cadenceTaps', min: 0, max: MetricLimits.maxCount),
        peakTapsPerSecond:
            json.optionalNumber('peakTapsPerSecond', min: 0, max: MetricLimits.maxTapsPerSecond),
        meanAsynchronyMs:
            json.optionalNumber('meanAsynchronyMs', min: 0, max: MetricLimits.maxAsynchronyMs),
      );

  static const BurstSummary empty =
      BurstSummary(burstTaps: 0, cadenceTaps: 0, peakTapsPerSecond: null, meanAsynchronyMs: null);

  final int burstTaps;
  final int cadenceTaps;
  final double? peakTapsPerSecond;
  final double? meanAsynchronyMs;

  Map<String, Object?> toJson() => {
        'burstTaps': burstTaps,
        'cadenceTaps': cadenceTaps,
        'peakTapsPerSecond': peakTapsPerSecond,
        'meanAsynchronyMs': meanAsynchronyMs,
      };
}

final class SessionResult {
  const SessionResult({
    required this.id,
    required this.mode,
    required this.startedAt,
    required this.dayKey,
    required this.durationMs,
    required this.dri,
    required this.reaction,
    required this.saccade,
    required this.burst,
  });

  factory SessionResult.fromJson(JsonGuard json) {
    final startedText = json.text('startedAt', pattern: _utcTimestamp);
    final startedAt = DateTime.tryParse(startedText);
    if (startedAt == null || !startedAt.isUtc) {
      throw DataFormatException('${json.path}.startedAt is not a UTC timestamp');
    }
    final mode = ProtocolMode.fromCode(json.text('mode', pattern: _modeCode));
    if (mode == null) {
      throw DataFormatException('${json.path}.mode is not an allowed value');
    }
    return SessionResult(
      id: json.text('id', pattern: _idPattern),
      mode: mode,
      startedAt: startedAt,
      dayKey: DayKey.parse(json.text('day', pattern: _dayText)),
      durationMs: json.integer('durationMs', min: 0, max: MetricLimits.maxDurationMs),
      dri: json.number('dri', min: 0, max: 100),
      reaction: ReactionSummary.fromJson(json.child('reaction')),
      saccade: SaccadeSummary.fromJson(json.child('saccade')),
      burst: BurstSummary.fromJson(json.child('burst')),
    );
  }

  static final RegExp _idPattern = RegExp(r'^[a-z0-9-]{1,40}$');
  static final RegExp _modeCode = RegExp(r'^[a-z]{1,8}$');
  static final RegExp _dayText = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final RegExp _utcTimestamp =
      RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$');

  static String idFor(DateTime startedAt, ProtocolMode mode) =>
      '${startedAt.microsecondsSinceEpoch.toRadixString(36)}-${mode.code}';

  final String id;
  final ProtocolMode mode;
  final DateTime startedAt;
  final DayKey dayKey;
  final int durationMs;
  final double dri;
  final ReactionSummary reaction;
  final SaccadeSummary saccade;
  final BurstSummary burst;

  double? get meanRtMs => reaction.meanRtMs;

  double get accuracy => reaction.accuracy;

  ConsistencyGrade? get grade => ConsistencyGrade.fromStdDev(reaction.stdDevMs);

  Map<String, Object?> toJson() => {
        'id': id,
        'mode': mode.code,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'day': dayKey.toString(),
        'durationMs': durationMs,
        'dri': dri,
        'reaction': reaction.toJson(),
        'saccade': saccade.toJson(),
        'burst': burst.toJson(),
      };
}

final class DailyBest {
  const DailyBest({required this.day, required this.best, required this.attempts});

  final DayKey day;
  final SessionResult? best;
  final int attempts;

  double? get bestDri => best?.dri;

  @override
  bool operator ==(Object other) =>
      other is DailyBest &&
      other.day == day &&
      other.attempts == attempts &&
      other.best?.id == best?.id;

  @override
  int get hashCode => Object.hash(day, attempts, best?.id);
}

final class RecordVerdict {
  const RecordVerdict({
    required this.ranked,
    required this.dri,
    required this.allTimeRank,
    required this.previousTodayBest,
  });

  const RecordVerdict.practice(this.dri)
      : ranked = false,
        allTimeRank = null,
        previousTodayBest = null;

  final bool ranked;
  final double dri;
  final int? allTimeRank;
  final double? previousTodayBest;

  double? get deltaToTodayBest {
    final previous = previousTodayBest;
    return previous == null ? null : dri - previous;
  }

  bool get isFirstRankedToday => ranked && previousTodayBest == null;

  bool get beatTodayBest => (deltaToTodayBest ?? 0) > 0;
}
