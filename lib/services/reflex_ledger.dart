import 'dart:convert';

import '../models/json_guard.dart';
import '../models/session_result.dart';
import 'dri_engine.dart';

final class ReflexLedger {
  ReflexLedger({
    required Iterable<SessionResult> sessions,
    required Iterable<SessionResult> hallOfFame,
  })  : sessions = List.unmodifiable(_uniqueById(sessions)..sort(_chronological)),
        hallOfFame = List.unmodifiable(_topRanked(hallOfFame));

  ReflexLedger.empty() : this(sessions: const [], hallOfFame: const []);

  static const int historyDays = 30;
  static const int hallSize = 3;
  static const int maxSessions = 3000;

  final List<SessionResult> sessions;
  final List<SessionResult> hallOfFame;

  static List<SessionResult> _uniqueById(Iterable<SessionResult> candidates) {
    final byId = <String, SessionResult>{};
    for (final session in candidates) {
      byId.putIfAbsent(session.id, () => session);
    }
    return byId.values.toList();
  }

  static int _chronological(SessionResult a, SessionResult b) {
    final byTime = a.startedAt.compareTo(b.startedAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }

  static int _hallOrder(SessionResult a, SessionResult b) {
    final byScore = b.dri.compareTo(a.dri);
    return byScore != 0 ? byScore : _chronological(a, b);
  }

  static List<SessionResult> _topRanked(Iterable<SessionResult> candidates) =>
      (_uniqueById(candidates.where((session) => session.mode.ranked))..sort(_hallOrder))
          .take(hallSize)
          .toList();

  static DayKey firstDayOfWindow(DayKey today) => today.shift(1 - historyDays);

  bool contains(String id) => sessions.any((session) => session.id == id);

  RecordVerdict verdictFor(SessionResult session) {
    if (!session.mode.ranked) {
      return RecordVerdict.practice(session.dri);
    }
    final standing = _topRanked([...hallOfFame, session]);
    final rankIndex = standing.indexWhere((entry) => entry.id == session.id);
    final earlierToday = sessions.where((entry) =>
        entry.mode.ranked && entry.dayKey == session.dayKey && entry.id != session.id);
    double? previousBest;
    for (final entry in earlierToday) {
      final best = previousBest;
      previousBest = best == null || entry.dri > best ? entry.dri : best;
    }
    return RecordVerdict(
      ranked: true,
      dri: session.dri,
      allTimeRank: rankIndex < 0 ? null : rankIndex + 1,
      previousTodayBest: previousBest,
    );
  }

  ReflexLedger recorded(SessionResult session, DayKey today) {
    if (contains(session.id)) {
      return this;
    }
    return ReflexLedger(
      sessions: [...sessions, session],
      hallOfFame: [...hallOfFame, session],
    ).pruned(today);
  }

  ReflexLedger mergedWith(ReflexLedger other, DayKey today) => ReflexLedger(
        sessions: [...sessions, ...other.sessions],
        hallOfFame: [...hallOfFame, ...other.hallOfFame, ...sessions, ...other.sessions],
      ).pruned(today);

  ReflexLedger pruned(DayKey today) {
    final earliest = firstDayOfWindow(today);
    final inWindow =
        sessions.where((session) => session.dayKey.compareTo(earliest) >= 0).toList();
    final overflow = inWindow.length - maxSessions;
    return ReflexLedger(
      sessions: overflow > 0 ? inWindow.sublist(overflow) : inWindow,
      hallOfFame: hallOfFame,
    );
  }

  List<SessionResult> sessionsOn(DayKey day) =>
      sessions.where((session) => session.dayKey == day).toList().reversed.toList();

  DailyBest dailyBestOn(DayKey day) => _dailyBest(day, sessions.where((s) => s.dayKey == day));

  List<DailyBest> dailyBests(DayKey today) {
    final sessionsByDay = <DayKey, List<SessionResult>>{};
    for (final session in sessions) {
      sessionsByDay.putIfAbsent(session.dayKey, () => []).add(session);
    }
    final earliest = firstDayOfWindow(today);
    return [
      for (final day in [for (var offset = 0; offset < historyDays; offset += 1) earliest.shift(offset)])
        _dailyBest(day, sessionsByDay[day] ?? const []),
    ];
  }

  static DailyBest _dailyBest(DayKey day, Iterable<SessionResult> sessionsThatDay) {
    final ranked = sessionsThatDay.where((session) => session.mode.ranked).toList()
      ..sort(_hallOrder);
    return DailyBest(day: day, best: ranked.firstOrNull, attempts: ranked.length);
  }
}

final class LedgerCodec {
  const LedgerCodec();

  static const String appTag = 'neuropulse';
  static const int schemaVersion = 1;
  static const int maxInputChars = 4000000;
  static const double driTolerance = 1e-6;
  static final RegExp _appPattern = RegExp('^$appTag\$');

  String encode(ReflexLedger ledger, {DateTime? exportedAt}) =>
      const JsonEncoder.withIndent(' ').convert({
        'app': appTag,
        'schemaVersion': schemaVersion,
        if (exportedAt != null) 'exportedAt': exportedAt.toUtc().toIso8601String(),
        'sessions': [for (final session in ledger.sessions) session.toJson()],
        'hallOfFame': [for (final session in ledger.hallOfFame) session.toJson()],
      });

  ReflexLedger decode(String raw) {
    if (raw.length > maxInputChars) {
      throw const DataFormatException('backup is larger than $maxInputChars characters');
    }
    final Object? root;
    try {
      root = jsonDecode(raw);
    } on FormatException {
      throw const DataFormatException('backup is not valid JSON');
    }
    final json = JsonGuard.from(root, 'backup');
    json.text('app', pattern: _appPattern);
    final version = json.integer('schemaVersion', min: 1, max: 1 << 30);
    if (version > schemaVersion) {
      throw DataFormatException('backup uses schema $version; this app reads up to $schemaVersion');
    }
    final sessions = [
      for (final entry in json.children('sessions', maxCount: ReflexLedger.maxSessions))
        _session(entry),
    ];
    final hall = [
      for (final entry in json.children('hallOfFame', maxCount: ReflexLedger.hallSize))
        _session(entry),
    ];
    _requireUniqueIds(sessions, 'backup.sessions');
    _requireUniqueIds(hall, 'backup.hallOfFame');
    if (hall.any((session) => !session.mode.ranked)) {
      throw const DataFormatException('backup.hallOfFame holds a practice session');
    }
    return ReflexLedger(sessions: sessions, hallOfFame: hall);
  }

  SessionResult _session(JsonGuard entry) {
    final session = SessionResult.fromJson(entry);
    final expected = const DriCalculator().score(session.reaction);
    if ((expected - session.dri).abs() > driTolerance) {
      throw DataFormatException('${entry.path}.dri does not match its own metrics');
    }
    return session;
  }

  static void _requireUniqueIds(List<SessionResult> sessions, String path) {
    final ids = sessions.map((session) => session.id).toSet();
    if (ids.length != sessions.length) {
      throw DataFormatException('$path repeats a session id');
    }
  }
}
