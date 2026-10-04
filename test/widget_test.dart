import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:daily_ielts/app_database.dart';
import 'package:daily_ielts/lock_channel.dart';
import 'package:daily_ielts/lock_gate.dart';
import 'package:daily_ielts/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Widget-level tests for the routing consequence of the gate: locked means the
/// test screen, free means the dashboard. The cooldown arithmetic itself is
/// covered in cooldown_test.dart; this file is only about what the user sees.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late DateTime clockNow;

  /// Permissions the fake platform reports. Tests override this to model a
  /// device where Android has granted, or refused, each capability.
  late PermissionState perms;

  setUpAll(() {
    sqfliteFfiInit();
    // The isolate-backed factory does real cross-isolate I/O, which cannot
    // complete inside the widget tester's fake-async zone -- the dashboard's
    // post-route-change load would hang forever. The no-isolate factory runs
    // sqlite in this isolate, so its futures settle on plain microtasks.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('widget_test');
    db = await AppDatabase.open(
      overridePath: '${tmp.path}${Platform.pathSeparator}widget.db',
    );
    clockNow = DateTime(2026, 10, 1, 12);
    // Default to a fully-working device so routing tests are not entangled with
    // the setup surface. Tests that care about permissions set this themselves.
    perms = const PermissionState(
      notifications: true,
      fullScreenIntent: true,
      exactAlarm: true,
      isDefaultHome: true,
    );
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

  /// Most screens sit behind onboarding. Tests that are not *about* onboarding
  /// declare it already finished so they test the screen they care about.
  Future<void> onboard() => db.setState(AppDatabase.kOnboarded, '1');

  /// Keyed on the current clock value so that changing [clockNow] and pumping
  /// again genuinely rebuilds the app state and re-runs the gate evaluation.
  /// Without this, Flutter reuses the existing State, `initState` never runs
  /// again, and a clock change would silently never be evaluated.
  Widget app() => DailyIeltsApp(
    key: ValueKey(clockNow.millisecondsSinceEpoch),
    db: db,
    gateBuilder: (d) => LockGate(
      database: d,
      clock: () => clockNow,
      permissionProbe: () async => perms,
      effects: GateEffects.inert,
    ),
    clock: () => clockNow,
    permissionProbe: () async => perms,
    // Never let this reach the real channel. An unregistered MethodChannel call
    // inside testWidgets' fake-async zone never completes -- the
    // MissingPluginException reply is delivered outside the fake clock -- so
    // _boot() would await it forever and the app would sit on its loading
    // spinner. Same reason clock and permissionProbe are injected above.
    launchPathReader: () async => 'session_start',
  );

  /// Grows the test surface so a whole screen fits in the tree.
  ///
  /// Every screen here is a ListView, which builds children lazily. At the
  /// default 800x600 the submit button and the onboarding status box sit below
  /// the fold and are never constructed, so finders cannot see them.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// Pumps until the app has settled on a screen.
  ///
  /// A bounded loop rather than `pumpAndSettle`: the loading state uses a
  /// `CircularProgressIndicator`, which animates forever, so pumpAndSettle
  /// would always time out on the frames it schedules.
  Future<void> pumpApp(WidgetTester tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(app());
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pump();
  }

  /// Answers one question by tapping the first choice inside that question's card.
  ///
  /// Not `find.byType(ChoiceRow).at(i)`: a ChoiceRow is one *option*, and the
  /// bank has several per question, so a positional index taps three options of
  /// the first question and leaves the rest blank.
  Future<void> answerQuestion(WidgetTester tester, int index) async {
    final card = find.byType(QuestionCard).at(index);
    await tester.ensureVisible(card);
    await tester.pump();
    final choice = find
        .descendant(of: card, matching: find.byType(ChoiceRow))
        .first;
    await tester.tap(choice);
    await tester.pump();
  }

  /// Answers every bundled question, then submits. The submit button is disabled
  /// until the whole bank is answered, by design.
  Future<void> answerAllAndSubmit(WidgetTester tester) async {
    final count = (await db.questions()).length;
    for (var i = 0; i < count; i++) {
      await answerQuestion(tester, i);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Submit and continue'));
    await pumpApp(tester);
  }

  group('the gate is owed a test', () {
    testWidgets('no completed test -> the test screen, not the dashboard', (
      tester,
    ) async {
      await pumpApp(tester);

      expect(find.text('Your 24 hour window has closed'), findsOneWidget);
      expect(find.text('Take a practice test'), findsNothing);
    });

    testWidgets('submit stays disabled until every question is answered', (
      tester,
    ) async {
      await pumpApp(tester);

      // Three questions, three remaining.
      expect(find.text('3 remaining'), findsOneWidget);
      final disabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Answer all questions to continue'),
      );
      expect(disabled.onPressed, isNull);
    });

    testWidgets('answering all questions enables submit', (tester) async {
      await pumpApp(tester);

      final count = (await db.questions()).length;
      for (var i = 0; i < count; i++) {
        await answerQuestion(tester, i);
      }

      expect(find.text('All answered'), findsOneWidget);
      final enabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Submit and continue'),
      );
      expect(enabled.onPressed, isNotNull);
    });

    testWidgets('the elapsed readout advances on its own while idle', (
      tester,
    ) async {
      // Regression guard: with no ticker the screen only rebuilt when the user
      // touched something, so an idle user watched a frozen timer.
      //
      // The clock here is mutable but the widget key is stable, so the only
      // thing that can repaint the label is the ticker firing.
      var now = DateTime(2026, 10, 1, 12);
      useTallSurface(tester);
      await tester.pumpWidget(
        DailyIeltsApp(
          key: const ValueKey('elapsed'),
          db: db,
          gateBuilder: (d) => LockGate(
            database: d,
            clock: () => now,
            permissionProbe: () async => perms,
            effects: GateEffects.inert,
          ),
          clock: () => now,
          permissionProbe: () async => perms,
          launchPathReader: () async => 'session_start',
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      }
      expect(find.text('0h 00m 00s'), findsOneWidget);

      now = now.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 61));

      expect(find.text('0h 01m 01s'), findsOneWidget);
    });

    testWidgets('completing a test releases the lock and shows the dashboard', (
      tester,
    ) async {
      // Expired, so the test screen is up. Onboarding would sit between the
      // test and the dashboard, so declare it finished to observe the release.
      await onboard();
      await completeTestAt(DateTime(2026, 10, 1, 9));
      clockNow = DateTime(2026, 10, 3, 9);

      await pumpApp(tester);
      expect(find.text('Your 24 hour window has closed'), findsOneWidget);

      await answerAllAndSubmit(tester);

      expect(find.text('Your 24 hour window has closed'), findsNothing);
      expect(find.text('Take a practice test'), findsOneWidget);
      expect(await db.attemptCount(), 2);
    });

    testWidgets('a rolled-back clock still forces the test, and says why', (
      tester,
    ) async {
      await onboard();
      await completeTestAt(DateTime(2026, 10, 1, 9));

      // Establish a legitimate reading first, so a jump is detectable.
      clockNow = DateTime(2026, 10, 1, 15);
      await pumpApp(tester);
      expect(find.text('Take a practice test'), findsOneWidget);

      // Now wind the clock back before the completed test.
      clockNow = DateTime(2026, 10, 1, 2);
      await pumpApp(tester);

      expect(find.text('Clock rollback detected'), findsOneWidget);
      expect(find.textContaining('clock moved backwards'), findsOneWidget);
    });

    testWidgets('test screen cannot be dismissed with a back gesture', (
      tester,
    ) async {
      await pumpApp(tester);

      // automaticallyImplyLeading: false -- there is no way out except finishing.
      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.automaticallyImplyLeading, isFalse);
    });
  });

  group('inside the window', () {
    setUp(() => completeTestAt(DateTime(2026, 10, 1, 9)));

    testWidgets('shows the dashboard with a countdown', (tester) async {
      await onboard();
      clockNow = DateTime(2026, 10, 1, 20); // 11h in

      await pumpApp(tester);

      expect(find.text('Your 24 hour window has closed'), findsNothing);
      expect(find.text('Take a practice test'), findsOneWidget);
      expect(find.text('13h 00m 00s'), findsOneWidget);
    });

    testWidgets('counts completed tests and bypasses separately', (
      tester,
    ) async {
      await onboard();
      await db.logLockEvent(kind: 'home_undo', at: clockNow);
      clockNow = DateTime(2026, 10, 1, 20);

      await pumpApp(tester);

      expect(find.text('Tests completed'), findsOneWidget);
      expect(find.text('Lock bypasses on record'), findsOneWidget);
      expect(find.text('1'), findsWidgets); // attempts and bypasses both 1
    });
  });

  group('onboarding', () {
    testWidgets('runs before the dashboard on a fresh install', (tester) async {
      await completeTestAt(DateTime(2026, 10, 1, 9));
      clockNow = DateTime(2026, 10, 1, 20);

      await pumpApp(tester);

      expect(find.text('Daily IELTS'), findsOneWidget);
      expect(find.text('Set Daily IELTS as your Home app'), findsOneWidget);
      expect(find.text('Take a practice test'), findsNothing);
    });

    testWidgets('blocks Finish setup while no gate can enforce', (
      tester,
    ) async {
      // Nothing granted: the app cannot interrupt at all.
      perms = PermissionState.unknown;
      await completeTestAt(DateTime(2026, 10, 1, 9));
      clockNow = DateTime(2026, 10, 1, 20);

      await pumpApp(tester);

      expect(find.text('The gate cannot enforce anything yet'), findsOneWidget);
      final finish = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Finish setup'),
      );
      expect(finish.onPressed, isNull);
    });

    testWidgets('reaches the dashboard once a gate is active', (tester) async {
      perms = const PermissionState(
        notifications: true,
        fullScreenIntent: true,
        exactAlarm: false,
        isDefaultHome: true,
      );
      await completeTestAt(DateTime(2026, 10, 1, 9));
      clockNow = DateTime(2026, 10, 1, 20);

      await pumpApp(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Finish setup'));
      await pumpApp(tester);

      expect(find.text('Take a practice test'), findsOneWidget);
      expect(await db.getState(AppDatabase.kOnboarded), '1');
    });
  });

  group('unenforceable state is visible', () {
    testWidgets('dashboard warns when notifications are off', (tester) async {
      perms = const PermissionState(
        notifications: false,
        fullScreenIntent: true,
        exactAlarm: true,
        isDefaultHome: true,
      );
      await onboard();
      await completeTestAt(DateTime(2026, 10, 1, 9));
      clockNow = DateTime(2026, 10, 1, 20);

      await pumpApp(tester);

      expect(find.text('Notifications are off'), findsOneWidget);
    });

    testWidgets('dashboard warns when the alarm was refused', (tester) async {
      perms = const PermissionState(
        notifications: true,
        fullScreenIntent: true,
        exactAlarm: false,
        isDefaultHome: true,
      );
      await onboard();
      await completeTestAt(DateTime(2026, 10, 1, 9));
      clockNow = DateTime(2026, 10, 1, 20);

      await pumpApp(tester);

      expect(find.text('Exact alarms are off'), findsOneWidget);
    });
  });
}
