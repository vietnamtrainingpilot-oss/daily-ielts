import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:daily_ielts/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;

  setUpAll(() {
    // Unit tests run on the host, where the plugin's method channel does not
    // exist. Point sqflite at the ffi implementation so the real SQL, real
    // transactions, and real constraints are exercised rather than mocked.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('daily_ielts_test');
    db = await AppDatabase.open(
      overridePath: '${tmp.path}${Platform.pathSeparator}test.db',
    );
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('fresh install', () {
    test('has never completed a test', () async {
      expect(await db.getLastCompletedAt(), isNull);
      expect(await db.attemptCount(), 0);
    });

    test('ships a seeded question bank', () async {
      final n = await db.db.rawQuery('SELECT COUNT(*) FROM questions');
      // sqflite returns [{c: n}]
      expect(n.first.values.first, AppDatabase.bundledQuestions.length);
    });

    test('seeded choices decode as real JSON', () async {
      final rows = await db.db.query(
        'questions',
        where: 'id = ?',
        whereArgs: ['p1-q001'],
      );
      final choices = decodeChoices(rows.first['choices'] as String);
      expect(choices, contains('stimulate'));
      expect(choices.length, 4);
    });
  });

  group('recording a completed test', () {
    test('writes the attempt and resets the window', () async {
      final at = DateTime(2026, 10, 1, 9);
      await db.recordAttempt(
        completedAt: at,
        durationSeconds: 600,
        band: 7.5,
        correctCount: 8,
        totalCount: 10,
      );

      expect(await db.attemptCount(), 1);
      expect(await db.getLastCompletedAt(), at);
    });

    test(
      'a second attempt overwrites the window rather than duplicating it',
      () async {
        await db.recordAttempt(
          completedAt: DateTime(2026, 10, 1, 9),
          durationSeconds: 600,
          band: 7.5,
          correctCount: 8,
          totalCount: 10,
        );
        final later = DateTime(2026, 10, 2, 9);
        await db.recordAttempt(
          completedAt: later,
          durationSeconds: 600,
          band: 8.0,
          correctCount: 9,
          totalCount: 10,
        );

        expect(await db.attemptCount(), 2);
        // One authoritative value: the most recent completion.
        expect(await db.getLastCompletedAt(), later);
        final rows = await db.db.query(
          'state',
          where: 'key = ?',
          whereArgs: [AppDatabase.kLastCompletedAt],
        );
        expect(rows.length, 1);
      },
    );
  });

  group('bypass events (AGENTS.md section 6)', () {
    test('are recorded, not prevented', () async {
      final at = DateTime(2026, 10, 1, 9);
      await db.logLockEvent(kind: 'home_undo', at: at);
      await db.logLockEvent(kind: 'home_undo', at: at);
      await db.logLockEvent(kind: 'lock_bypass', at: at);

      expect(await db.lockEventCount(), 3);
      expect(await db.lockEventCount(kind: 'home_undo'), 2);
      expect(await db.lockEventCount(kind: 'lock_bypass'), 1);
    });

    test('recording one does not touch the cooldown window', () async {
      final at = DateTime(2026, 10, 1, 9);
      await db.recordAttempt(
        completedAt: at,
        durationSeconds: 600,
        band: 7.5,
        correctCount: 8,
        totalCount: 10,
      );
      await db.logLockEvent(kind: 'home_undo', at: at);

      // A bypass must never be a way to earn extra time.
      expect(await db.getLastCompletedAt(), at);
    });
  });

  group('clock tamper detection storage', () {
    test('round-trips the last observed clock reading', () async {
      expect(await db.lastSeenClock(), isNull);
      final now = DateTime(2026, 10, 1, 9, 30);
      await db.recordClockSeen(now);
      expect(await db.lastSeenClock(), now);
    });
  });

  test('state survives a reopen', () async {
    final at = DateTime(2026, 10, 1, 9);
    await db.recordAttempt(
      completedAt: at,
      durationSeconds: 600,
      band: 7.5,
      correctCount: 8,
      totalCount: 10,
    );
    await db.close();

    final reopened = await AppDatabase.open(
      overridePath: '${tmp.path}${Platform.pathSeparator}test.db',
    );
    // This is the whole point: a force-close must not reset the 24h window.
    expect(await reopened.getLastCompletedAt(), at);
    expect(await reopened.attemptCount(), 1);
    await reopened.close();
  });
}
