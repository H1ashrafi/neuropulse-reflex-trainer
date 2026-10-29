import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neuropulse/models/json_guard.dart';
import 'package:neuropulse/models/session_result.dart';
import 'package:neuropulse/services/reflex_ledger.dart';

import 'support/fakes.dart';

final DayKey today = DayKey.of(2026, 10, 27);

ReflexLedger ledgerOf(List<SessionResult> sessions) =>
    sessions.fold(ReflexLedger.empty(), (ledger, session) => ledger.recorded(session, today));

Map<String, Object?> backupMap(ReflexLedger ledger) =>
    jsonDecode(const LedgerCodec().encode(ledger)) as Map<String, Object?>;

Matcher rejectedWith(String fragment) =>
    throwsA(isA<DataFormatException>().having((error) => error.message, 'message', contains(fragment)));

void main() {
  group('DayKey', () {
    test('parses real calendar days and refuses impossible ones', () {
      expect(DayKey.parse('2024-02-29').toString(), '2024-02-29');
      expect(() => DayKey.parse('2026-02-30'), throwsA(isA<DataFormatException>()));
      expect(() => DayKey.parse('2026-13-01'), throwsA(isA<DataFormatException>()));
      expect(() => DayKey.parse('26-1-1'), throwsA(isA<DataFormatException>()));
    });

    test('shifts across month and year boundaries without drifting', () {
      expect(DayKey.of(2026, 12, 31).shift(1), DayKey.of(2027, 1, 1));
      expect(DayKey.of(2026, 3, 1).shift(-1), DayKey.of(2026, 2, 28));
      expect(DayKey.of(2026, 10, 27).daysSince(DayKey.of(2026, 9, 28)), 29);
    });
  });

  group('30-day rolling window', () {
    test('keeps today and the 29 days before it and drops day 31', () {
      final kept = SessionFactory.make(day: today.shift(-29), dri: 50);
      final dropped = SessionFactory.make(day: today.shift(-30), dri: 40);
      final ledger = ledgerOf([dropped, kept, SessionFactory.make(day: today, dri: 45)]);
      expect(ledger.sessions.map((s) => s.id), isNot(contains(dropped.id)));
      expect(ledger.sessions.map((s) => s.id), contains(kept.id));
    });

    test('pruning never removes an all-time top 3 record', () {
      final ancient = SessionFactory.make(day: today.shift(-200), dri: 97);
      final ledger = ledgerOf([ancient, SessionFactory.make(day: today, dri: 60)]);
      expect(ledger.sessions.any((s) => s.id == ancient.id), isFalse);
      expect(ledger.hallOfFame.first.id, ancient.id);
    });

    test('caps the history at the newest maxSessions entries', () {
      final crowd = [
        for (var index = 0; index < ReflexLedger.maxSessions + 5; index += 1)
          SessionFactory.make(day: today, dri: 30, mode: ProtocolMode.simpleReaction),
      ];
      final ledger = ReflexLedger(sessions: crowd, hallOfFame: const []).pruned(today);
      expect(ledger.sessions.length, ReflexLedger.maxSessions);
      expect(ledger.sessions.last.id, crowd.last.id);
    });

    test('daily bests cover exactly 30 days ending today, with peak and ranked attempt count', () {
      final ledger = ledgerOf([
        SessionFactory.make(day: today, dri: 61, hour: 8),
        SessionFactory.make(day: today, dri: 74, hour: 12),
        SessionFactory.make(day: today, dri: 69, hour: 18),
        SessionFactory.make(day: today, dri: 99, mode: ProtocolMode.simpleReaction),
        SessionFactory.make(day: today.shift(-3), dri: 55),
      ]);
      final days = ledger.dailyBests(today);
      expect(days.length, 30);
      expect(days.first.day, today.shift(-29));
      expect(days.last.day, today);
      expect(days.last.bestDri, closeTo(74, 1e-9));
      expect(days.last.attempts, 3);
      expect(days[26].bestDri, closeTo(55, 1e-9));
      expect(days[25].best, isNull);
    });

    test('recording the same session twice keeps one copy', () {
      final session = SessionFactory.make(day: today, dri: 70);
      final ledger = ledgerOf([session, session]);
      expect(ledger.sessions.length, 1);
    });
  });

  group('all-time top 3', () {
    test('holds the three highest ranked scores in descending order', () {
      final ledger = ledgerOf([
        for (final dri in [40.0, 88.0, 71.0, 93.0, 65.0]) SessionFactory.make(day: today, dri: dri),
      ]);
      expect(ledger.hallOfFame.map((s) => s.dri.round()), [93, 88, 71]);
    });

    test('practice modules never enter the hall even with a perfect score', () {
      final ledger = ledgerOf([
        SessionFactory.make(day: today, dri: 100, mode: ProtocolMode.simpleReaction),
        SessionFactory.make(day: today, dri: 50),
      ]);
      expect(ledger.hallOfFame.map((s) => s.mode), everyElement(ProtocolMode.fullProtocol));
    });

    test('an equal score ranks below the earlier holder because a record must be beaten', () {
      final first = SessionFactory.make(day: today.shift(-2), dri: 80);
      final ledger = ledgerOf([first]);
      final tie = SessionFactory.make(day: today, dri: 80);
      expect(ledger.verdictFor(tie).allTimeRank, 2);
      expect(ledger.recorded(tie, today).hallOfFame.first.id, first.id);
    });
  });

  group('verdicts', () {
    test('first ranked attempt of the day, then beat, then fall short', () {
      var ledger = ledgerOf([SessionFactory.make(day: today.shift(-1), dri: 90)]);
      final opener = SessionFactory.make(day: today, dri: 60, hour: 7);
      expect(ledger.verdictFor(opener).isFirstRankedToday, isTrue);
      ledger = ledger.recorded(opener, today);
      final better = SessionFactory.make(day: today, dri: 66.5, hour: 8);
      final betterVerdict = ledger.verdictFor(better);
      expect(betterVerdict.beatTodayBest, isTrue);
      expect(betterVerdict.deltaToTodayBest, closeTo(6.5, 1e-9));
      ledger = ledger.recorded(better, today);
      final worse = SessionFactory.make(day: today, dri: 61, hour: 9);
      expect(ledger.verdictFor(worse).beatTodayBest, isFalse);
      expect(ledger.verdictFor(worse).deltaToTodayBest, closeTo(-5.5, 1e-9));
    });

    test('a new all-time high is rank #1 and a practice run is unranked', () {
      final ledger = ledgerOf([SessionFactory.make(day: today, dri: 70)]);
      expect(ledger.verdictFor(SessionFactory.make(day: today, dri: 91)).allTimeRank, 1);
      final practice = ledger.verdictFor(SessionFactory.make(day: today, dri: 99, mode: ProtocolMode.goNoGo));
      expect(practice.ranked, isFalse);
      expect(practice.allTimeRank, isNull);
    });
  });

  group('LedgerCodec', () {
    const codec = LedgerCodec();
    final sample = ledgerOf([
      SessionFactory.make(day: today, dri: 72.25),
      SessionFactory.make(day: today.shift(-4), dri: 64),
      SessionFactory.make(day: today, dri: 58, mode: ProtocolMode.quickProtocol),
    ]);

    test('round-trips every field', () {
      final restored = codec.decode(codec.encode(sample, exportedAt: DateTime.utc(2026, 10, 27)));
      expect(restored.sessions.map((s) => s.toJson()), sample.sessions.map((s) => s.toJson()));
      expect(restored.hallOfFame.map((s) => s.id), sample.hallOfFame.map((s) => s.id));
    });

    test('merging a backup into itself changes nothing', () {
      final merged = sample.mergedWith(codec.decode(codec.encode(sample)), today);
      expect(merged.sessions.length, sample.sessions.length);
      expect(merged.hallOfFame.map((s) => s.id), sample.hallOfFame.map((s) => s.id));
    });

    test('rejects text that is not JSON', () {
      expect(() => codec.decode('{nope'), rejectedWith('not valid JSON'));
    });

    test('rejects a root that is not an object', () {
      expect(() => codec.decode('[1,2,3]'), rejectedWith('must be an object'));
    });

    test('rejects backups from another app', () {
      final foreign = backupMap(sample)..['app'] = 'other';
      expect(() => codec.decode(jsonEncode(foreign)), rejectedWith('backup.app'));
    });

    test('rejects a newer schema instead of guessing', () {
      final future = backupMap(sample)..['schemaVersion'] = 2;
      expect(() => codec.decode(jsonEncode(future)), rejectedWith('schema 2'));
    });

    test('rejects input over the size cap before parsing it', () {
      final huge = ' ' * (LedgerCodec.maxInputChars + 1);
      expect(() => codec.decode(huge), rejectedWith('larger than'));
    });

    test('survives 200000 levels of nesting without exhausting the stack', () {
      final deep = '${'[' * 200000}${']' * 200000}';
      expect(() => codec.decode(deep), throwsA(isA<DataFormatException>()));
    });

    test('rejects a score that does not match its own metrics', () {
      final tampered = backupMap(sample);
      ((tampered['sessions'] as List<Object?>).first as Map<String, Object?>)['dri'] = 99.9;
      expect(() => codec.decode(jsonEncode(tampered)), rejectedWith('does not match'));
    });

    test('rejects counts that do not add up', () {
      final broken = backupMap(sample);
      final reaction = ((broken['sessions'] as List<Object?>).first as Map<String, Object?>)['reaction']
          as Map<String, Object?>;
      reaction['hits'] = 3;
      expect(() => codec.decode(jsonEncode(broken)), rejectedWith('do not add up'));
    });

    test('rejects out-of-range and non-finite numbers', () {
      final huge = backupMap(sample);
      ((huge['sessions'] as List<Object?>).first as Map<String, Object?>)['durationMs'] = -1;
      expect(() => codec.decode(jsonEncode(huge)), rejectedWith('durationMs'));
      final raw = codec.encode(sample).replaceFirst(RegExp(r'"dri": [0-9.]+'), '"dri": 1e400');
      expect(() => codec.decode(raw), rejectedWith('dri'));
    });

    test('rejects hostile ids and does not echo them back', () {
      const hostile = '../../<script>alert(1)</script>';
      final attack = backupMap(sample);
      ((attack['sessions'] as List<Object?>).first as Map<String, Object?>)['id'] = hostile;
      expect(
        () => codec.decode(jsonEncode(attack)),
        throwsA(isA<DataFormatException>().having((e) => e.message, 'message', isNot(contains('script')))),
      );
    });

    test('rejects timestamps that are not UTC', () {
      final local = backupMap(sample);
      ((local['sessions'] as List<Object?>).first as Map<String, Object?>)['startedAt'] =
          '2026-10-27T10:00:00+02:00';
      expect(() => codec.decode(jsonEncode(local)), rejectedWith('startedAt'));
    });

    test('rejects duplicate ids, oversized halls and practice sessions in the hall', () {
      final duplicated = backupMap(sample);
      final sessions = duplicated['sessions'] as List<Object?>;
      sessions.add(sessions.first);
      expect(() => codec.decode(jsonEncode(duplicated)), rejectedWith('repeats a session id'));

      final crowdedHall = backupMap(sample);
      final hall = crowdedHall['hallOfFame'] as List<Object?>;
      crowdedHall['hallOfFame'] = [...hall, ...hall, ...hall];
      expect(() => codec.decode(jsonEncode(crowdedHall)), rejectedWith('more than 3'));

      final practiceHall = backupMap(sample);
      final practiceEntry =
          Map<String, Object?>.of((practiceHall['hallOfFame'] as List<Object?>).first as Map<String, Object?>)
            ..['mode'] = 'srt';
      practiceHall['hallOfFame'] = [practiceEntry];
      expect(() => codec.decode(jsonEncode(practiceHall)), rejectedWith('practice session'));
    });

    test('rejects a missing field by name', () {
      final missing = backupMap(sample);
      ((missing['sessions'] as List<Object?>).first as Map<String, Object?>).remove('burst');
      expect(() => codec.decode(jsonEncode(missing)), rejectedWith('burst is missing'));
    });
  });
}
