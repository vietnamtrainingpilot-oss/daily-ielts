/// Local persistence. Single writer, single source of truth.
///
/// AGENTS.md section 7: the database holds history only. It never decides
/// whether a test is due -- [Cooldown] does that from the timestamps stored
/// here, behind an injected clock.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _fileName = 'daily_ielts.db';
  static const _version = 1;

  /// Opens the database, creating and seeding it on first run.
  ///
  /// [overridePath] exists so tests can run against a temp directory instead of
  /// the platform documents directory.
  static Future<AppDatabase> open({String? overridePath}) async {
    final path =
        overridePath ??
        p.join((await getApplicationDocumentsDirectory()).path, _fileName);

    final database = await openDatabase(
      path,
      version: _version,
      onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      onCreate: (d, _) async {
        // Completed-test history.
        await d.execute('''
          CREATE TABLE attempts (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            completed_at  INTEGER NOT NULL,
            duration_s    INTEGER NOT NULL,
            band          REAL    NOT NULL,
            correct_count INTEGER NOT NULL,
            total_count   INTEGER NOT NULL
          )
        ''');

        // Lock/bypass audit trail. Recorded, never used to block.
        await d.execute('''
          CREATE TABLE lock_events (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            kind         TEXT    NOT NULL,
            occurred_at  INTEGER NOT NULL,
            detail       TEXT
          )
        ''');

        // Bundled question bank. Created before seeding, obviously.
        await d.execute('''
          CREATE TABLE questions (
            id           TEXT PRIMARY KEY,
            section      TEXT    NOT NULL,
            prompt       TEXT    NOT NULL,
            choices      TEXT    NOT NULL,
            answer_index INTEGER NOT NULL,
            time_limit_s INTEGER NOT NULL
          )
        ''');

        // One row per key, not a table of settings: this is the single mutable
        // piece of state the lock logic reads, and it must not be able to hold
        // two contradictory rows.
        await d.execute('''
          CREATE TABLE state (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');

        final batch = d.batch();
        for (final q in bundledQuestions) {
          batch.insert(
            'questions',
            q,
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        await batch.commit(noResult: true);
      },
    );

    return AppDatabase._(database);
  }

  // ---- state key/value -------------------------------------------------

  static const kLastCompletedAt = 'last_completed_at';
  static const kOnboarded = 'onboarded';
  static const kLastSeenClock = 'last_seen_clock';
  static const kAnswersInProgress = 'answers_in_progress';

  /// All instants are stored as epoch milliseconds, which is timezone-free, and
  /// are handed back as **local** [DateTime]s.
  ///
  /// Local is the right choice for this app: the 24h window and the tamper rule
  /// are about the device's wall clock, which is what the user can see and
  /// change. Note that `DateTime.==` also compares the UTC flag, so compare these
  /// against local times rather than UTC ones.
  Future<String?> getState(String key) async {
    final rows = await db.query('state', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  Future<DateTime?> getLastCompletedAt() async {
    final raw = await getState(kLastCompletedAt);
    return raw == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(int.parse(raw));
  }

  Future<void> setState(String key, String value) => db.insert('state', {
    'key': key,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> clearState(String key) =>
      db.delete('state', where: 'key = ?', whereArgs: [key]);

  /// Records the current wall clock so the next session can detect a backward
  /// jump (AGENTS.md section 5).
  Future<void> recordClockSeen(DateTime now) =>
      setState(kLastSeenClock, now.millisecondsSinceEpoch.toString());

  Future<DateTime?> lastSeenClock() async {
    final raw = await getState(kLastSeenClock);
    return raw == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(int.parse(raw));
  }

  // ---- attempts --------------------------------------------------------

  /// Records a completed test and stamps [kLastCompletedAt] in one transaction.
  ///
  /// Both writes land together or neither does. A completed test that failed to
  /// reset the 24h window is the worst possible bug in this app.
  Future<void> recordAttempt({
    required DateTime completedAt,
    required int durationSeconds,
    required double band,
    required int correctCount,
    required int totalCount,
  }) async {
    await db.transaction((txn) async {
      await txn.insert('attempts', {
        'completed_at': completedAt.millisecondsSinceEpoch,
        'duration_s': durationSeconds,
        'band': band,
        'correct_count': correctCount,
        'total_count': totalCount,
      });
      await txn.insert('state', {
        'key': kLastCompletedAt,
        'value': completedAt.millisecondsSinceEpoch.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<int> attemptCount() async =>
      Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM attempts'),
      ) ??
      0;

  // ---- lock events -----------------------------------------------------

  Future<void> logLockEvent({
    required String kind,
    required DateTime at,
    String? detail,
  }) => db.insert('lock_events', {
    'kind': kind,
    'occurred_at': at.millisecondsSinceEpoch,
    'detail': detail,
  });

  Future<int> lockEventCount({String? kind}) async {
    final rows = kind == null
        ? await db.rawQuery('SELECT COUNT(*) FROM lock_events')
        : await db.rawQuery('SELECT COUNT(*) FROM lock_events WHERE kind = ?', [
            kind,
          ]);
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  // ---- questions --------------------------------------------------------

  /// The bundled bank, in stable order.
  Future<List<Question>> questions() async {
    final rows = await db.query('questions', orderBy: 'id ASC');
    return rows.map(Question.fromRow).toList();
  }

  /// Clears every saved answer. Called after a completed attempt so the next
  /// test starts from a blank slate rather than replaying the last one.
  Future<void> clearAnswers() => saveAnswers(const {});

  // ---- in-progress answer autosave --------------------------------------

  /// Persists the answers given so far.
  ///
  /// If the process dies mid-test -- which is easy to arrange on a device that
  /// reboots to fix a clock, exactly the situation this app creates -- the work
  /// is still there. Stored as JSON in the single-row `state` table rather than
  /// a new table, because Phase 1 needs no schema beyond what exists.
  Future<void> saveAnswers(Map<String, int> byQuestionId) async {
    await setState(kAnswersInProgress, jsonEncode(byQuestionId));
  }

  /// Previously autosaved answers, or empty if there are none.
  Future<Map<String, int>> loadAnswers() async {
    final raw = await getState(kAnswersInProgress);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
    } on FormatException {
      // Corrupt autosave must never block the gate. The user simply redoes the
      // test; failing here would be a worse outcome than losing answers.
      return const {};
    }
  }

  Future<void> close() => db.close();

  // ---- bundled question bank -------------------------------------------

  /// Starter bank so the app is runnable end to end in Phase 1. The full bank
  /// is content work, not engineering work.
  static const bundledQuestions = <Map<String, Object?>>[
    {
      'id': 'p1-q001',
      'section': 'listening',
      'prompt': 'Which word does the speaker stress?',
      'choices': '["simulate", "stimulate", "accumulate", "calculate"]',
      'answer_index': 1,
      'time_limit_s': 30,
    },
    {
      'id': 'p1-q002',
      'section': 'reading',
      'prompt': 'The main function of the device is to:',
      'choices':
          '["store water", "measure humidity", "power a lamp", "count steps"]',
      'answer_index': 1,
      'time_limit_s': 45,
    },
    {
      'id': 'p1-q003',
      'section': 'writing',
      'prompt': 'In one sentence: does the trend increase or decrease?',
      'choices': '["Increase", "Decrease", "Stay flat"]',
      'answer_index': 1,
      'time_limit_s': 60,
    },
  ];
}

/// Deterministic band estimate from a raw correct/total pair.
///
/// Phase 1 has no rubric and must not invent one, so this is an honest linear
/// rescale of the fraction correct onto the 0-9 band scale rather than a claim
/// about academic performance. Phase 2 replaces this with real grading.
double estimateBand({required int correct, required int total}) =>
    total == 0 ? 0 : (correct / total) * 9;

/// Exposed so tests can decode the stored `choices` column.
List<String> decodeChoices(String raw) =>
    (jsonDecode(raw) as List).cast<String>();

/// One question, with the user's answer attached in memory.
///
/// `selectedIndex` is deliberately not persisted on the question row: answers are
/// autosaved separately via [AppDatabase.saveAnswers] so that a partial test
/// survives without polluting the question bank.
class Question {
  const Question({
    required this.id,
    required this.section,
    required this.prompt,
    required this.choices,
    required this.answerIndex,
    required this.timeLimitSeconds,
    this.selectedIndex,
  });

  final String id;

  /// `reading` / `listening` / `writing`, used for the DESIGN.md skill tint.
  final String section;
  final String prompt;
  final List<String> choices;
  final int answerIndex;
  final int timeLimitSeconds;

  /// Null means unanswered.
  final int? selectedIndex;

  bool get isAnswered => selectedIndex != null;

  Question withAnswer(int? index) => Question(
    id: id,
    section: section,
    prompt: prompt,
    choices: choices,
    answerIndex: answerIndex,
    timeLimitSeconds: timeLimitSeconds,
    selectedIndex: index,
  );

  factory Question.fromRow(Map<String, Object?> r) => Question(
    id: r['id'] as String,
    section: r['section'] as String,
    prompt: r['prompt'] as String,
    choices: decodeChoices(r['choices'] as String),
    answerIndex: r['answer_index'] as int,
    timeLimitSeconds: r['time_limit_s'] as int,
  );
}
