import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:daily_ielts/app_database.dart';
import 'package:daily_ielts/lock_channel.dart';
import 'package:daily_ielts/lock_gate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;

  // Controllable clock. Every test advances it explicitly; nothing sleeps.
  late DateTime clockNow;

  setUpAll(() {
    // The gate asks the platform what it permits. These are pure-Dart tests, so
    // there is no native handler: the binding gives us the real
    // "nothing implemented this" path, which must degrade to unknown rather
    // than throw. Same behaviour a Windows build gets.
    TestWidgetsFlutterBinding.ensureInitialized();

    // Host-side unit tests: sqflite's plugin channel does not exist here, so
    // point it at the ffi implementation and get real SQL.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gate_test');
    db = await AppDatabase.open(
      overridePath: '${tmp.path}${Platform.pathSeparator}gate.db',
    );
    clockNow = DateTime(2026, 10, 1, 12);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> completeTestAt(DateTime at) => db.recordAttempt(
    completedAt: at,
    durationSeconds: 600,
    band: 7.5,
    correctCount: 8,
    totalCount: 10,
  );

  group('fresh install, no test ever done', () {
    test('both paths demand a test', () async {
      final gate = LockGate(database: db, clock: () => clockNow);
      final viaSession = await gate.evaluate(TriggerPath.sessionStart);
      final viaAlarm = await gate.evaluate(TriggerPath.scheduledFire);

      expect(viaSession.outcome, GateOutcome.mustTest);
      expect(viaAlarm.outcome, GateOutcome.mustTest);
    });

    test('the two paths cannot disagree -- same answer either way', () async {
      clockNow = DateTime(2026, 10, 1, 12);
      final a = await LockGate(
        database: db,
        clock: () => clockNow,
      ).evaluate(TriggerPath.sessionStart);

      clockNow = DateTime(2026, 10, 1, 18);
      final b = await LockGate(
        database: db,
        clock: () => clockNow,
      ).evaluate(TriggerPath.scheduledFire);

      // Different instants, same verdict: nothing has been completed.
      expect(a.isLocked, isTrue);
      expect(b.isLocked, isTrue);
    });
  });

  group('inside the 24h window', () {
    setUp(() => completeTestAt(DateTime(2026, 10, 1, 9)));

    test('session start lets the device be used', () async {
      clockNow = DateTime(2026, 10, 1, 20); // 11h later
      final gate = LockGate(database: db, clock: () => clockNow);
      final r = await gate.evaluate(TriggerPath.sessionStart);

      expect(r.outcome, GateOutcome.free);
      expect(r.isLocked, isFalse);
    });

    test('scheduled fire outside the window does not force a test', () async {
      clockNow = DateTime(2026, 10, 1, 20);
      final gate = LockGate(database: db, clock: () => clockNow);
      final r = await gate.evaluate(TriggerPath.scheduledFire);

      expect(r.outcome, GateOutcome.free);
    });

    test('arms Path 2 for exactly the moment the window closes', () async {
      final scheduled = <DateTime>[];
      final gate = LockGate(
        database: db,
        clock: () => clockNow,
        effects: GateEffects(
          schedule: (t) async {
            scheduled.add(t);
            return true;
          },
          cancel: () async {},
          warn: (_) async {},
        ),
      );

      clockNow = DateTime(2026, 10, 1, 20);
      final r = await gate.evaluate(TriggerPath.sessionStart);

      expect(scheduled, [DateTime(2026, 10, 2, 9)]);
      expect(r.triggerAt, DateTime(2026, 10, 2, 9));
      expect(r.pathTwoArmed, isTrue);
    });

    test('reports the alarm as NOT armed when Android refuses', () async {
      // Android rejects setAlarmClock without SCHEDULE_EXACT_ALARM. The gate
      // must surface that rather than assume the schedule succeeded.
      final gate = LockGate(
        database: db,
        clock: () => clockNow,
        effects: GateEffects(
          schedule: (_) async => false,
          cancel: () async {},
          warn: (_) async {},
        ),
      );

      clockNow = DateTime(2026, 10, 1, 20);
      final r = await gate.evaluate(TriggerPath.sessionStart);

      expect(r.outcome, GateOutcome.free);
      expect(r.triggerAt, isNotNull);
      expect(r.pathTwoArmed, isFalse);
    });

    test('does NOT fire the grace warning on every evaluation', () async {
      // Regression guard. The 2-minute heads-up is scheduled natively for
      // triggerAt - 2min. Warning from here fired it the instant the app
      // opened, spamming the user on every session.
      final warnings = <int>[];
      final gate = LockGate(
        database: db,
        clock: () => clockNow,
        effects: GateEffects(
          schedule: (_) async => true,
          cancel: () async {},
          warn: (m) async => warnings.add(m),
        ),
      );

      clockNow = DateTime(2026, 10, 1, 20);
      await gate.evaluate(TriggerPath.sessionStart);
      await gate.evaluate(TriggerPath.sessionStart);
      await gate.evaluate(TriggerPath.sessionStart);

      expect(warnings, isEmpty);
    });

    test('marks the device unenforceable when neither path can fire', () async {
      // No permissions at all: the app looks installed and correct but cannot
      // interrupt anything. That state must be visible, not implied-safe.
      final gate = LockGate(
        database: db,
        clock: () => clockNow,
        permissionProbe: () async => PermissionState.unknown,
        effects: GateEffects(
          schedule: (_) async => false,
          cancel: () async {},
          warn: (_) async {},
        ),
      );

      clockNow = DateTime(2026, 10, 1, 20);
      final r = await gate.evaluate(TriggerPath.sessionStart);

      expect(r.outcome, GateOutcome.free);
      expect(r.isUnenforceable, isTrue);
    });
  });

  group('at and after the 24h mark', () {
    setUp(() => completeTestAt(DateTime(2026, 10, 1, 9)));

    test('exactly 24h locks', () async {
      clockNow = DateTime(2026, 10, 2, 9);
      final r = await LockGate(
        database: db,
        clock: () => clockNow,
      ).evaluate(TriggerPath.sessionStart);
      expect(r.outcome, GateOutcome.mustTest);
    });

    test('locks and cancels the pending alarm', () async {
      var cancels = 0;
      final gate = LockGate(
        database: db,
        clock: () => clockNow,
        effects: GateEffects(
          schedule: (_) async => true,
          cancel: () async => cancels++,
          warn: (_) async {},
        ),
      );

      clockNow = DateTime(2026, 10, 2, 9);
      final r = await gate.evaluate(TriggerPath.sessionStart);

      expect(r.isLocked, isTrue);
      expect(cancels, greaterThan(0));
    });

    test('hours past the mark still locks', () async {
      clockNow = DateTime(2026, 10, 5, 9);
      final r = await LockGate(
        database: db,
        clock: () => clockNow,
      ).evaluate(TriggerPath.scheduledFire);
      expect(r.isLocked, isTrue);
    });
  });

  group('clock rollback -- AGENTS.md section 5', () {
    setUp(() => completeTestAt(DateTime(2026, 10, 1, 9)));

    test('rolling back inside the window forces the lock', () async {
      final gate = LockGate(database: db, clock: () => clockNow);

      // Observe the clock at a legitimate time so there is evidence to compare.
      clockNow = DateTime(2026, 10, 1, 15);
      expect(
        (await gate.evaluate(TriggerPath.sessionStart)).outcome,
        GateOutcome.free,
      );

      // Now the user winds the clock back to before the test was completed.
      clockNow = DateTime(2026, 10, 1, 2);
      final r = await gate.evaluate(TriggerPath.sessionStart);

      // Arithmetic alone would say "not due". The rollback must override it.
      expect(r.cooldown.isExpired, isFalse);
      expect(r.outcome, GateOutcome.mustTestTampered);
      expect(r.isLocked, isTrue);
    });

    test('the rollback is recorded as its own event kind', () async {
      final gate = LockGate(database: db, clock: () => clockNow);
      clockNow = DateTime(2026, 10, 1, 15);
      await gate.evaluate(TriggerPath.sessionStart);
      clockNow = DateTime(2026, 10, 1, 2);
      await gate.evaluate(TriggerPath.sessionStart);

      expect(await db.lockEventCount(kind: 'clock_rollback'), 1);
    });

    test('normal forward progress is never flagged as tampering', () async {
      final gate = LockGate(database: db, clock: () => clockNow);
      clockNow = DateTime(2026, 10, 1, 15);
      await gate.evaluate(TriggerPath.sessionStart);
      clockNow = DateTime(2026, 10, 1, 16);
      final r = await gate.evaluate(TriggerPath.sessionStart);

      expect(r.outcome, GateOutcome.free);
      expect(await db.lockEventCount(kind: 'clock_rollback'), 0);
    });
  });

  test('clock evidence is read before it is overwritten', () async {
    // Guards the ordering inside evaluate(): if recordClockSeen ran first, every
    // second session would see "no change" and tampering would never be caught.
    final gate = LockGate(database: db, clock: () => clockNow);
    clockNow = DateTime(2026, 10, 1, 15);
    await gate.evaluate(TriggerPath.sessionStart);
    clockNow = DateTime(2026, 10, 1, 2);
    final r = await gate.evaluate(TriggerPath.sessionStart);

    expect(r.outcome, GateOutcome.mustTestTampered);
  });
}
