import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/json_guard.dart';
import '../models/session_result.dart';
import 'reflex_ledger.dart';

export 'reflex_ledger.dart';

abstract interface class KeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

final class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore([SharedPreferencesAsync? preferences])
      : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> read(String key) => _preferences.getString(key);

  @override
  Future<void> write(String key, String value) => _preferences.setString(key, value);
}

final class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

typedef WallClock = DateTime Function();

final class StorageUnavailableException implements Exception {
  const StorageUnavailableException();

  @override
  String toString() => 'phone storage is unavailable';
}

final class RecordReceipt {
  const RecordReceipt({required this.verdict, required this.saveProblem});

  final RecordVerdict verdict;
  final String? saveProblem;

  bool get saved => saveProblem == null;
}

final class ImportReport {
  const ImportReport({required this.addedSessions, required this.totalSessions});

  final int addedSessions;
  final int totalSessions;
}

final class ReflexRepository extends ChangeNotifier {
  ReflexRepository(this._store, {WallClock? clock, this._codec = const LedgerCodec()})
      : _clock = clock ?? DateTime.now;

  static const String ledgerKey = 'neuropulse.ledger';
  static const String quarantinePrefix = 'neuropulse.quarantine.';

  final KeyValueStore _store;
  final WallClock _clock;
  final LedgerCodec _codec;
  ReflexLedger _ledger = ReflexLedger.empty();
  String? _loadWarning;
  bool _storageUnavailable = false;
  Future<void> _pendingWrite = Future<void>.value();

  ReflexLedger get ledger => _ledger;

  String? get loadWarning => _loadWarning;

  DayKey get today => DayKey.fromLocal(_clock());

  bool get canSave => !_storageUnavailable;

  Future<void> load() async {
    try {
      await _loadFromStore();
    } on Exception {
      _storageUnavailable = true;
      _ledger = ReflexLedger.empty();
      _loadWarning = 'Phone storage is unavailable right now. Results will show but will not be saved.';
    }
    notifyListeners();
  }

  Future<void> _loadFromStore() async {
    final raw = await _store.read(ledgerKey);
    if (raw == null) {
      _ledger = ReflexLedger.empty();
      return;
    }
    try {
      _ledger = _codec.decode(raw).pruned(today);
    } on DataFormatException catch (problem) {
      await _store.write('$quarantinePrefix${_clock().microsecondsSinceEpoch}', raw);
      _ledger = ReflexLedger.empty();
      _loadWarning =
          'Saved history could not be read (${problem.message}). A copy was set aside and a fresh history started.';
    }
  }

  void dismissLoadWarning() {
    _loadWarning = null;
    notifyListeners();
  }

  Future<RecordReceipt> record(SessionResult session) async {
    final verdict = _ledger.verdictFor(session);
    _ledger = _ledger.recorded(session, today);
    notifyListeners();
    try {
      await _persist();
    } on Exception catch (problem) {
      return RecordReceipt(verdict: verdict, saveProblem: problem.toString());
    }
    return RecordReceipt(verdict: verdict, saveProblem: null);
  }

  String exportJson() => _codec.encode(_ledger, exportedAt: _clock());

  Future<ImportReport> importJson(String raw) async {
    final incoming = _codec.decode(raw);
    final knownIds = {for (final session in _ledger.sessions) session.id};
    _ledger = _ledger.mergedWith(incoming, today);
    final added = _ledger.sessions.where((session) => !knownIds.contains(session.id)).length;
    notifyListeners();
    await _persist();
    return ImportReport(addedSessions: added, totalSessions: _ledger.sessions.length);
  }

  Future<void> _persist() {
    if (_storageUnavailable) {
      return Future<void>.error(const StorageUnavailableException());
    }
    final snapshot = _codec.encode(_ledger);
    final write = _pendingWrite.then((_) => _store.write(ledgerKey, snapshot));
    _pendingWrite = write.catchError((Object _) {});
    return write;
  }
}
