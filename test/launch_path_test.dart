import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:daily_ielts/app_database.dart';
import 'package:daily_ielts/lock_channel.dart';
import 'package:daily_ielts/lock_gate.dart';
import 'package:daily_ielts/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// AGENTS.md section 7 declares `onScheduledFire` as a native -> Dart event, but
/// nothing native ever emitted it, so every Path 2 interrupt was recorded as
/// `session_start`. These tests pin the corrected behaviour: Dart asks which
/// launch path brought it up, evaluates exactly once, and records that label.
///
/// The double-evaluation risk is the reason this is a pull rather than a push.
/// `LockGate.evaluate` writes a LockEvent every time it is locked, so a boot
/// evaluation *plus* a pushed event would count one interrupt twice. The
/// `total == 1` assertions below are what would catch a regression back into
/// the push design.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late DateTime clockNow;
  late PermissionState perms;

  setUpAll(() {
    sqfliteFfiInit();
    // Same reason as widget_test.dart: the isolate-backed factory cannot settle
    // its cross-isolate I/O inside the tester's fake-async zone.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('launch_path_test');
    db = await AppDatabase.open(
      overridePath: '${tmp.path}${Platform.pathSeparator}launch.db',
    );
    clockNow = DateTime(2026, 10, 1, 12);
    perms = const PermissionState(
      notifications: true,
      fullScreenIntent: true,
      exactAlarm: true,
      isDefaultHome: true,
    );
    // No attempt has ever been recorded, so the gate is locked on boot and an
    // event is written. That is the state a scheduled interrupt lands in.
    await db.setState(AppDatabase.kOnboarded, '1');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Widget app({required Future<String?> Function() reader}) => DailyIeltsApp(
    db: db,
    gateBuilder: (d) => LockGate(
      database: d,
      clock: () => clockNow,
      permissionProbe: () async => perms,
      effects: GateEffects.inert,
    ),
    clock: () => clockNow,
    permissionProbe: () async => perms,
    launchPathReader: reader,
  );

  Future<void> pumpApp(WidgetTester tester, Future<String?> Function() reader) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(reader: reader));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pump();
  }

  group('pathForLabel', () {
    test('maps the native labels onto their trigger paths', () {
      expect(pathForLabel('scheduled_fire'), TriggerPath.scheduledFire);
      expect(pathForLabel('session_start'), TriggerPath.sessionStart);
    });

    test('falls back to session_start for a missing or unknown label', () {
      // Not a security question: both paths reach the same gate decision, so
      // only the recorded label is at stake.
      expect(pathForLabel(null), TriggerPath.sessionStart);
      expect(pathForLabel(''), TriggerPath.sessionStart);
      expect(pathForLabel('something_else'), TriggerPath.sessionStart);
    });
  });

  group('launch path recorded at boot', () {
    testWidgets('a scheduled interrupt is recorded as scheduled_fire', (
      tester,
    ) async {
      await pumpApp(tester, () async => 'scheduled_fire');

      expect(await db.lockEventCount(kind: 'scheduled_fire'), 1);
      expect(await db.lockEventCount(kind: 'session_start'), 0);
    });

    testWidgets('an ordinary launch is recorded as session_start', (
      tester,
    ) async {
      await pumpApp(tester, () async => 'session_start');

      expect(await db.lockEventCount(kind: 'session_start'), 1);
      expect(await db.lockEventCount(kind: 'scheduled_fire'), 0);
    });

    testWidgets('a platform with no launch query falls back cleanly', (
      tester,
    ) async {
      // Non-Android and channel-less test runs land here; the gate must not
      // see an exception from a cosmetic query.
      await pumpApp(tester, () async => null);

      expect(await db.lockEventCount(kind: 'session_start'), 1);
      expect(await db.lockEventCount(), 1);
    });

    testWidgets('exactly one event per interrupt, not two', (tester) async {
      // The assertion that distinguishes the pull design from a push design.
      await pumpApp(tester, () async => 'scheduled_fire');

      expect(await db.lockEventCount(), 1);
    });
  });
}
