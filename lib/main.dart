/// Daily IELTS -- Phase 1.
///
/// AGENTS.md section 8 makes `DESIGN.md` the single source of truth for visual
/// identity. Every colour, radius, and type size in this file resolves through
/// `design_tokens.dart`, which mirrors that document.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'app_database.dart';
import 'design_tokens.dart';
import 'lock_channel.dart';
import 'lock_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  runApp(DailyIeltsApp(db: db));
}

/// Injected so tests can supply a stub instead of a platform channel.
typedef GateBuilder = LockGate Function(AppDatabase db);

class DailyIeltsApp extends StatefulWidget {
  const DailyIeltsApp({
    super.key,
    required this.db,
    this.gateBuilder,
    this.clock,
    this.permissionProbe,
  });

  final AppDatabase db;
  final GateBuilder? gateBuilder;

  /// The one time source for the whole app. The gate must judge and the test
  /// screen must stamp completions with the *same* clock, otherwise a
  /// completion can be recorded at a different instant than the one the gate
  /// evaluates against.
  final DateTime Function()? clock;

  /// Overrides the real platform probe. Tests and non-Android platforms get
  /// [PermissionState.unknown] without touching a MethodChannel.
  final Future<PermissionState> Function()? permissionProbe;

  @override
  State<DailyIeltsApp> createState() => _DailyIeltsAppState();
}

class _DailyIeltsAppState extends State<DailyIeltsApp> {
  /// Assigned once, in initState.
  late LockGate _gate;

  /// Null until the first evaluation finishes. The UI waits for a real answer
  /// rather than optimistically showing "you're free" and then snatching it.
  GateResult? _result;
  bool _testOpen = false;
  bool _onboarded = false;
  PermissionState _perms = PermissionState.unknown;

  @override
  void initState() {
    super.initState();

    final probe = widget.permissionProbe ?? LockChannel.permissionStatus;

    if (widget.gateBuilder != null) {
      // A test supplied the gate (clock and/or effects already wired).
      _gate = widget.gateBuilder!(widget.db);
    } else {
      _gate = LockGate(
        database: widget.db,
        clock: widget.clock,
        permissionProbe: probe,
        effects: GateEffects(
          schedule: LockChannel.startSchedule,
          cancel: LockChannel.cancelSchedule,
          warn: (m) => LockChannel.sendGraceWarning(minutes: m),
        ),
      );
    }

    LockChannel.install();
    LockChannel.onSessionStart = () => _evaluate(TriggerPath.sessionStart);
    LockChannel.onScheduledFire = () => _evaluate(TriggerPath.scheduledFire);
    LockChannel.onPermissionsChanged = (p) {
      if (mounted) setState(() => _perms = p);
    };

    _boot();
  }

  Future<void> _boot() async {
    final onboarded = await widget.db.getState(AppDatabase.kOnboarded);
    final perms =
        await (widget.permissionProbe ?? LockChannel.permissionStatus)();
    if (!mounted) return;
    setState(() {
      _onboarded = onboarded == '1';
      _perms = perms;
    });
    await _evaluate(TriggerPath.sessionStart);
  }

  Future<void> _evaluate(TriggerPath path) async {
    final result = await _gate.evaluate(path);
    if (!mounted) return;
    setState(() {
      _result = result;
      _perms = result.permissions;
      if (result.isLocked) _testOpen = true;
    });
  }

  /// Records an observed change in the HOME setting as a bypass event.
  ///
  /// AGENTS.md section 6: log it, show it, never prevent it.
  Future<void> _noteHomeUndoIfNeeded(PermissionState next) async {
    if (_perms.isDefaultHome && !next.isDefaultHome) {
      await widget.db.logLockEvent(
        kind: 'home_undo',
        at: (widget.clock ?? DateTime.now)(),
        detail: 'Default Home app was changed away from Daily IELTS',
      );
    }
    if (!mounted) return;
    setState(() => _perms = next);
  }

  Future<void> _refreshPermissions() async {
    final next =
        await (widget.permissionProbe ?? LockChannel.permissionStatus)();
    await _noteHomeUndoIfNeeded(next);
    await _evaluate(TriggerPath.sessionStart);
  }

  Future<void> _onTestCompleted(DateTime at) async {
    // recordAttempt stamps the window in the same transaction as the attempt,
    // so re-evaluate immediately afterwards against the new truth.
    await widget.db.clearAnswers();
    await _evaluate(TriggerPath.sessionStart);
    if (mounted) setState(() => _testOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Daily IELTS',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: _home(),
    );
  }

  Widget _home() {
    final result = _result;
    if (result == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // The gate outranks onboarding. If a test is owed, that is the only thing
    // this screen may be.
    if (result.isLocked || _testOpen) {
      return TestScreen(
        key: const ValueKey('test'),
        result: result,
        db: widget.db,
        clock: widget.clock ?? DateTime.now,
        onCompleted: _onTestCompleted,
      );
    }

    if (!_onboarded) {
      return OnboardingScreen(
        key: const ValueKey('onboarding'),
        permissions: _perms,
        onGrantNotifications: LockChannel.requestNotificationPermission,
        onOpenSetting: LockChannel.openPermissionSettings,
        onSetHome: LockChannel.openHomeSettings,
        onRefresh: _refreshPermissions,
        onFinish: () async {
          await widget.db.setState(AppDatabase.kOnboarded, '1');
          if (mounted) setState(() => _onboarded = true);
        },
      );
    }

    return DashboardScreen(
      key: const ValueKey('dashboard'),
      result: result,
      db: widget.db,
      permissions: _perms,
      onStartTest: () => setState(() => _testOpen = true),
      onOpenSetting: LockChannel.openPermissionSettings,
      onSetHome: LockChannel.openHomeSettings,
      onRefresh: _refreshPermissions,
    );
  }
}

// ---------------------------------------------------------------------------
// Onboarding
//
// Runs before the gate can bite. Setting this app as HOME is a one-way door --
// if it becomes the launcher with no permission behind it, the device looks
// broken until the user finds Settings. Everything is explained up front.
// ---------------------------------------------------------------------------

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.permissions,
    required this.onGrantNotifications,
    required this.onOpenSetting,
    required this.onSetHome,
    required this.onRefresh,
    required this.onFinish,
  });

  final PermissionState permissions;
  final Future<PermissionState> Function() onGrantNotifications;
  final Future<bool> Function(String kind) onOpenSetting;
  final Future<void> Function() onSetHome;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onFinish;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late PermissionState _p = widget.permissions;

  Future<void> _grant() async {
    final next = await widget.onGrantNotifications();
    if (mounted) setState(() => _p = next);
  }

  Future<void> _refresh() async {
    await widget.onRefresh();
    if (mounted) setState(() => _p = widget.permissions);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Setup')),
      body: ListView(
        padding: const EdgeInsets.all(Tokens.spaceMd),
        children: [
          Text('Daily IELTS', style: t.textTheme.headlineMedium),
          const SizedBox(height: Tokens.spaceSm),
          Text(
            'This app requires you to complete one short IELTS test every 24 '
            'hours. Outside that window your phone behaves exactly as normal.',
            style: t.textTheme.bodyLarge,
          ),
          const SizedBox(height: Tokens.spaceLg),
          _Section(
            title: 'Required',
            child: Column(
              children: [
                _Step(
                  n: 1,
                  title: 'Allow notifications',
                  detail:
                      'Without this, the reminder before a due test never '
                      'appears and the interrupt is a blind surprise.',
                  done: _p.notifications,
                  actionLabel: _p.notifications ? null : 'Allow',
                  onAction: _grant,
                ),
                _Step(
                  n: 2,
                  title: 'Allow full-screen alerts',
                  detail:
                      'Lets the due test take over the screen even when the '
                      'app is closed. Android 14+ grants this with a toggle.',
                  done: _p.fullScreenIntent,
                  actionLabel: _p.fullScreenIntent ? null : 'Open settings',
                  onAction: () => widget.onOpenSetting('fullScreenIntent'),
                ),
                _Step(
                  n: 3,
                  title: 'Allow exact alarms',
                  detail:
                      'Required to schedule the test moment precisely. '
                      'Without it the scheduled path is silently disabled.',
                  done: _p.exactAlarm,
                  actionLabel: _p.exactAlarm ? null : 'Open settings',
                  onAction: () => widget.onOpenSetting('exactAlarm'),
                ),
                _Step(
                  n: 4,
                  title: 'Set Daily IELTS as your Home app',
                  detail:
                      'This is how the gate runs when you unlock the phone. '
                      'You can undo it any time in Android settings.',
                  done: _p.isDefaultHome,
                  actionLabel: _p.isDefaultHome ? null : 'Choose Home app',
                  onAction: widget.onSetHome,
                ),
              ],
            ),
          ),
          const SizedBox(height: Tokens.spaceMd),
          if (!_p.pathTwoArmed)
            NoticeBox(
              tone: _p.isDefaultHome ? NoticeTone.warning : NoticeTone.danger,
              title: _p.isDefaultHome
                  ? 'Scheduled interruptions are off'
                  : 'The gate cannot enforce anything yet',
              body: _p.isDefaultHome
                  ? 'The gate still runs when you unlock the phone, but a test '
                        'that becomes due while you are already using the device '
                        'will not interrupt you until your next unlock.'
                  : 'Until the steps above are done this app cannot stop you '
                        'using the phone. Nothing is being enforced right now.',
            ),
          const SizedBox(height: Tokens.spaceMd),
          OutlinedButton(
            onPressed: _refresh,
            child: const Text('Re-check status'),
          ),
          const SizedBox(height: Tokens.spaceSm),
          FilledButton(
            onPressed: _p.hasWorkingPath ? widget.onFinish : null,
            child: const Text('Finish setup'),
          ),
          if (!_p.hasWorkingPath) ...[
            const SizedBox(height: Tokens.spaceSm),
            Text(
              'Finish setup stays disabled until at least one gate is active.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.result,
    required this.db,
    required this.permissions,
    required this.onStartTest,
    required this.onOpenSetting,
    required this.onSetHome,
    required this.onRefresh,
  });

  final GateResult result;
  final AppDatabase db;
  final PermissionState permissions;
  final VoidCallback onStartTest;
  final Future<bool> Function(String kind) onOpenSetting;
  final Future<void> Function() onSetHome;
  final Future<void> Function() onRefresh;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int _attempts = 0;
  int _bypasses = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DashboardScreen old) {
    super.didUpdateWidget(old);
    if (old.result != widget.result) _load();
  }

  Future<void> _load() async {
    final attempts = await widget.db.attemptCount();
    final bypasses =
        await widget.db.lockEventCount(kind: 'home_undo') +
        await widget.db.lockEventCount(kind: 'lock_bypass');
    if (!mounted) return;
    setState(() {
      _attempts = attempts;
      _bypasses = bypasses;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final remaining = widget.result.cooldown.remaining;
    final p = widget.permissions;

    return Scaffold(
      appBar: AppBar(title: const Text('Daily IELTS')),
      body: ListView(
        padding: const EdgeInsets.all(Tokens.spaceMd),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Tokens.spaceMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Next test due', style: t.textTheme.labelMedium),
                  const SizedBox(height: Tokens.spaceXs),
                  Text(
                    remaining == null ? 'Now' : _hms(remaining),
                    // DESIGN.md: counters must be tabular so they do not jitter.
                    style: t.textTheme.headlineMedium?.copyWith(
                      fontFeatures: kTabularFigures,
                    ),
                  ),
                  const SizedBox(height: Tokens.spaceSm),
                  Row(
                    children: [
                      StatusDot(
                        ok: widget.result.pathTwoArmed || p.isDefaultHome,
                      ),
                      const SizedBox(width: Tokens.spaceSm),
                      Expanded(
                        child: Text(
                          widget.result.pathTwoArmed
                              ? 'Scheduled alarm armed'
                              : (widget.result.triggerAt == null
                                    ? 'No alarm armed'
                                    : 'Scheduled alarm NOT armed'),
                          style: t.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          if (!p.notifications) ...[
            const SizedBox(height: Tokens.spaceMd),
            NoticeBox(
              tone: NoticeTone.warning,
              title: 'Notifications are off',
              body:
                  'Reminders will not appear. The test still gates you when '
                  'you unlock the phone.',
              actionLabel: 'Fix',
              onAction: () => widget.onOpenSetting('notifications'),
            ),
          ],
          if (!p.exactAlarm) ...[
            const SizedBox(height: Tokens.spaceSm),
            NoticeBox(
              tone: NoticeTone.warning,
              title: 'Exact alarms are off',
              body:
                  'The scheduled test moment cannot be set, so an overdue '
                  'test is only caught on your next unlock.',
              actionLabel: 'Fix',
              onAction: () => widget.onOpenSetting('exactAlarm'),
            ),
          ],
          if (!p.isDefaultHome) ...[
            const SizedBox(height: Tokens.spaceSm),
            NoticeBox(
              tone: NoticeTone.info,
              title: 'Daily IELTS is not your Home app',
              body:
                  'The gate only runs on unlock while this app is the '
                  'default Home app.',
              actionLabel: 'Set as Home',
              onAction: widget.onSetHome,
            ),
          ],

          const SizedBox(height: Tokens.spaceLg),
          FilledButton.icon(
            onPressed: widget.onStartTest,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Take a practice test'),
          ),

          const SizedBox(height: Tokens.spaceLg),
          StatRow(label: 'Tests completed', value: '$_attempts'),
          const SizedBox(height: Tokens.spaceXs),
          // AGENTS.md section 6: bypasses are surfaced, never prevented.
          StatRow(label: 'Lock bypasses on record', value: '$_bypasses'),
          if (_bypasses > 0) ...[
            const SizedBox(height: Tokens.spaceSm),
            Text(
              'Bypasses cannot be prevented or blocked. They are recorded so '
              'the record stays honest.',
              style: t.textTheme.bodySmall,
            ),
          ],

          const SizedBox(height: Tokens.spaceLg),
          OutlinedButton(
            onPressed: widget.onRefresh,
            child: const Text('Re-check permissions'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

class TestScreen extends StatefulWidget {
  const TestScreen({
    super.key,
    required this.result,
    required this.db,
    required this.clock,
    required this.onCompleted,
  });

  final GateResult result;
  final AppDatabase db;

  /// Same time source the gate uses. See [DailyIeltsApp.clock].
  final DateTime Function() clock;

  final Future<void> Function(DateTime at) onCompleted;

  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> {
  final Map<String, int> _answers = {};
  List<Question> _questions = const [];
  bool _loading = true;
  int _startedAtMs = 0;

  /// Repaints the elapsed readout once a second.
  ///
  /// Without this the clock only advances when something else rebuilds the
  /// screen, so a user sitting on the test sees a frozen timer. The value is
  /// still derived from the injected clock -- the timer only decides how often
  /// to ask, never what time it is.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _startedAtMs = widget.clock().millisecondsSinceEpoch;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final questions = await widget.db.questions();
    // Restore any autosave so a reboot mid-test does not lose the work.
    final saved = await widget.db.loadAnswers();
    if (!mounted) return;
    setState(() {
      _questions = questions;
      _answers
        ..clear()
        ..addAll(saved);
      _loading = false;
    });
  }

  int get _elapsedSeconds {
    final now = widget.clock().millisecondsSinceEpoch;
    final s = (now - _startedAtMs) ~/ 1000;
    return s < 0 ? 0 : s;
  }

  Future<void> _choose(Question q, int index) async {
    setState(() => _answers[q.id] = index);
    await widget.db.saveAnswers(_answers);
  }

  Future<void> _finish(bool tampered) async {
    final at = widget.clock();
    final answered = _questions
        .map(
          (q) => _answers.containsKey(q.id) ? q.withAnswer(_answers[q.id]) : q,
        )
        .toList();
    final correct = answered
        .where(
          (q) => q.selectedIndex != null && q.selectedIndex == q.answerIndex,
        )
        .length;
    await widget.db.recordAttempt(
      completedAt: at,
      durationSeconds: _elapsedSeconds,
      band: estimateBand(correct: correct, total: answered.length),
      correctCount: correct,
      totalCount: answered.length,
    );
    await widget.onCompleted(at);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tampered = widget.result.outcome == GateOutcome.mustTestTampered;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Daily test'),
          automaticallyImplyLeading: false,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final unanswered = _questions
        .where((q) => !_answers.containsKey(q.id))
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily test'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(Tokens.spaceMd),
        children: [
          Text(
            tampered
                ? 'Clock rollback detected'
                : 'Your 24 hour window has closed',
            style: t.textTheme.headlineSmall,
          ),
          const SizedBox(height: Tokens.spaceXs),
          Text(
            tampered
                ? 'The device clock moved backwards. The test is required '
                      'anyway. Answer every question to continue.'
                : 'Answer every question to continue using this device.',
            style: t.textTheme.bodyMedium,
          ),
          const SizedBox(height: Tokens.spaceMd),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Tokens.spaceMd),
              child: Row(
                children: [
                  Text('Elapsed', style: t.textTheme.labelMedium),
                  const SizedBox(width: Tokens.spaceSm),
                  Text(
                    _hms(Duration(seconds: _elapsedSeconds)),
                    style: t.textTheme.headlineSmall?.copyWith(
                      fontFeatures: kTabularFigures,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    unanswered == 0 ? 'All answered' : '$unanswered remaining',
                    style: t.textTheme.bodySmall?.copyWith(
                      color: unanswered == 0
                          ? Tokens.gateMet
                          : Tokens.gateCaution,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Tokens.spaceMd),
          for (final q in _questions) ...[
            QuestionCard(
              question: q,
              selectedIndex: _answers[q.id],
              onSelect: (i) => _choose(q, i),
            ),
            const SizedBox(height: Tokens.spaceMd),
          ],
          FilledButton(
            // Enabled only when everything is answered: a half-finished test
            // must not reset the 24 hour window.
            onPressed: _questions.isEmpty || unanswered > 0
                ? null
                : () => _finish(tampered),
            child: Text(
              unanswered > 0
                  ? 'Answer all questions to continue'
                  : 'Submit and continue',
            ),
          ),
          const SizedBox(height: Tokens.spaceSm),
          Text(
            'Answers save automatically. If the phone restarts mid-test your '
            'answers are kept.',
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

/// One question with its choices. Full-width block selectors per DESIGN.md.
class QuestionCard extends StatelessWidget {
  const QuestionCard({
    super.key,
    required this.question,
    required this.selectedIndex,
    required this.onSelect,
  });

  final Question question;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Tokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SkillTag(section: question.section),
                const Spacer(),
                Text(
                  '${question.timeLimitSeconds}s suggested',
                  style: t.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: Tokens.spaceSm),
            Text(question.prompt, style: t.textTheme.bodyLarge),
            const SizedBox(height: Tokens.spaceMd),
            for (var i = 0; i < question.choices.length; i++) ...[
              ChoiceRow(
                label: question.choices[i],
                selected: selectedIndex == i,
                onTap: () => onSelect(i),
              ),
              if (i != question.choices.length - 1)
                const SizedBox(height: Tokens.spaceXs),
            ],
          ],
        ),
      ),
    );
  }
}

/// Muted background tint with high-contrast text, per DESIGN.md skill tags.
class SkillTag extends StatelessWidget {
  const SkillTag({super.key, required this.section});

  final String section;

  (Color, Color) get _pair => switch (section) {
    'reading' => (Tokens.skillReadingBg, Tokens.skillReadingInk),
    'listening' => (Tokens.skillListeningBg, Tokens.skillListeningInk),
    'writing' => (Tokens.skillWritingBg, Tokens.skillWritingInk),
    _ => (Tokens.skillSpeakingBg, Tokens.skillSpeakingInk),
  };

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _pair;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Tokens.spaceSm,
        vertical: Tokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: bg,
        // DESIGN.md: rectangular or 4px. Never a pill.
        borderRadius: BorderRadius.circular(Tokens.radiusDefault),
      ),
      child: Text(
        section.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

class ChoiceRow extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Tokens.navyTint : Tokens.surface,
      borderRadius: BorderRadius.circular(Tokens.radiusDefault),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Tokens.radiusDefault),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: Tokens.spaceMd,
            vertical: Tokens.spaceSm + 2,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Tokens.radiusDefault),
            border: Border.all(
              color: selected ? Tokens.navy : Tokens.rule,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              // Radio marker: crisp ring, navy dot when selected.
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? Tokens.navy : Tokens.outline,
                    width: 1.5,
                  ),
                  color: selected ? Tokens.navy : Tokens.surface,
                ),
              ),
              const SizedBox(width: Tokens.spaceMd),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      children: [
        Expanded(child: Text(label, style: t.textTheme.bodyMedium)),
        Text(
          value,
          style: t.textTheme.labelLarge?.copyWith(
            fontFeatures: kTabularFigures,
          ),
        ),
      ],
    );
  }
}

/// Small filled/hollow marker for a boolean status line.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.ok});

  final bool ok;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: ok ? Tokens.gateMet : Tokens.strict,
    ),
  );
}

enum NoticeTone { info, warning, danger }

/// A bordered callout. Tone drives only the rule colour; the design keeps
/// structure over colour everywhere.
class NoticeBox extends StatelessWidget {
  const NoticeBox({
    super.key,
    required this.tone,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final NoticeTone tone;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  Color get _accent => switch (tone) {
    NoticeTone.info => Tokens.navy,
    NoticeTone.warning => Tokens.gateCaution,
    NoticeTone.danger => Tokens.strict,
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Tokens.spaceMd),
      decoration: BoxDecoration(
        color: Tokens.surface,
        borderRadius: BorderRadius.circular(Tokens.radiusLg),
        border: Border(left: BorderSide(color: _accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.textTheme.labelLarge),
          const SizedBox(height: Tokens.spaceXs),
          Text(body, style: t.textTheme.bodySmall),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: Tokens.spaceSm),
            OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(), style: t.textTheme.labelSmall),
        const SizedBox(height: Tokens.spaceSm),
        child,
      ],
    );
  }
}

/// One numbered setup step with a completion marker.
class _Step extends StatelessWidget {
  const _Step({
    required this.n,
    required this.title,
    required this.detail,
    required this.done,
    this.actionLabel,
    this.onAction,
  });

  final int n;
  final String title;
  final String detail;
  final bool done;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Tokens.spaceMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? Tokens.gateMet : Tokens.navyTint,
            ),
            child: done
                ? const Icon(Icons.check, size: 14, color: Tokens.surface)
                : Text('$n', style: t.textTheme.labelSmall),
          ),
          const SizedBox(width: Tokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.textTheme.labelLarge),
                const SizedBox(height: 2),
                Text(detail, style: t.textTheme.bodySmall),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: Tokens.spaceSm),
                  OutlinedButton(
                    onPressed: onAction,
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

String _hms(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return '${h}h ${mm}m ${ss}s';
}
