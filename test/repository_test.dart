import 'package:flutter_test/flutter_test.dart';
import 'package:neuropulse/models/json_guard.dart';
import 'package:neuropulse/models/session_result.dart';
import 'package:neuropulse/services/storage_service.dart';

import 'support/fakes.dart';

final DateTime noon = DateTime(2026, 10, 27, 12);
final DayKey today = DayKey.fromLocal(noon);

ReflexRepository repositoryOn(KeyValueStore store) => ReflexRepository(store, clock: () => noon);

void main() {
  test('a fresh install starts with an empty ledger and no warning', () async {
    final repository = repositoryOn(MemoryStore());
    await repository.load();
    expect(repository.ledger.sessions, isEmpty);
    expect(repository.loadWarning, isNull);
    expect(repository.canSave, isTrue);
  });

  test('recorded sessions survive a restart', () async {
    final store = MemoryStore();
    final first = repositoryOn(store);
    await first.load();
    final receipt = await first.record(SessionFactory.make(day: today, dri: 77));
    expect(receipt.saved, isTrue);
    expect(receipt.verdict.allTimeRank, 1);

    final second = repositoryOn(store);
    await second.load();
    expect(second.ledger.sessions.single.dri, closeTo(77, 1e-9));
    expect(second.ledger.hallOfFame.single.dri, closeTo(77, 1e-9));
  });

  test('unreadable saved data is set aside, not overwritten, and the user is told', () async {
    final store = MemoryStore()..values[ReflexRepository.ledgerKey] = '{"app":"neuropulse","schemaVersion":1';
    final repository = repositoryOn(store);
    await repository.load();
    final quarantined = store.values.entries
        .where((entry) => entry.key.startsWith(ReflexRepository.quarantinePrefix))
        .toList();
    expect(quarantined.single.value, '{"app":"neuropulse","schemaVersion":1');
    expect(repository.loadWarning, contains('could not be read'));
    expect(repository.ledger.sessions, isEmpty);
  });

  test('a broken store never loses the result on screen and reports why it was not saved', () async {
    final repository = repositoryOn(FailingStore());
    await repository.load();
    expect(repository.canSave, isFalse);
    expect(repository.loadWarning, contains('unavailable'));
    final receipt = await repository.record(SessionFactory.make(day: today, dri: 66));
    expect(receipt.saved, isFalse);
    expect(receipt.saveProblem, contains('unavailable'));
    expect(receipt.verdict.ranked, isTrue);
    expect(repository.ledger.sessions, hasLength(1));
  });

  test('writes land in call order even when the store answers out of order', () async {
    final store = SlowStore(const [Duration(milliseconds: 30), Duration(milliseconds: 1)]);
    final repository = repositoryOn(store);
    await repository.load();
    await Future.wait([
      repository.record(SessionFactory.make(day: today, dri: 50)),
      repository.record(SessionFactory.make(day: today, dri: 60)),
    ]);
    final reloaded = repositoryOn(store);
    await reloaded.load();
    expect(reloaded.ledger.sessions, hasLength(2));
  });

  test('import merges new sessions and reports how many were added', () async {
    final source = repositoryOn(MemoryStore());
    await source.load();
    await source.record(SessionFactory.make(day: today, dri: 81));
    await source.record(SessionFactory.make(day: today.shift(-1), dri: 70));

    final target = repositoryOn(MemoryStore());
    await target.load();
    await target.record(SessionFactory.make(day: today, dri: 64));
    final report = await target.importJson(source.exportJson());
    expect(report.addedSessions, 2);
    expect(report.totalSessions, 3);
    expect(target.ledger.hallOfFame.first.dri, closeTo(81, 1e-9));

    final again = await target.importJson(source.exportJson());
    expect(again.addedSessions, 0);
  });

  test('a rejected import leaves the ledger untouched', () async {
    final repository = repositoryOn(MemoryStore());
    await repository.load();
    await repository.record(SessionFactory.make(day: today, dri: 64));
    final before = repository.ledger;
    await expectLater(repository.importJson('{"app":"neuropulse"}'), throwsA(isA<DataFormatException>()));
    expect(identical(repository.ledger, before), isTrue);
  });

  test('practice sessions are stored but never ranked', () async {
    final repository = repositoryOn(MemoryStore());
    await repository.load();
    final receipt =
        await repository.record(SessionFactory.make(day: today, dri: 95, mode: ProtocolMode.simpleReaction));
    expect(receipt.verdict.ranked, isFalse);
    expect(repository.ledger.sessions, hasLength(1));
    expect(repository.ledger.hallOfFame, isEmpty);
  });
}
