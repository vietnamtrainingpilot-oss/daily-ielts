/// The gate. Every path into the app funnels through here and gets one answer.
///
/// AGENTS.md section 4: Path 1 (unlock / session start) and Path 2 (scheduled
/// interrupt) are not two rules, they are two *entry points* to this one. Both
/// call [evaluate]; there is deliberately no second place that decides whether a
/// test is due, because two rules would drift.
library;

import 'app_database.dart';
import 'cooldown.dart';
import 'lock_channel.dart';

/// Which entry point asked. Affects logging only -- never the outcome.
enum TriggerPath {
  sessionStart,
  scheduledFire;

  String get label => switch (this) {
    TriggerPath.sessionStart => 'session_start',
    TriggerPath.scheduledFire => 'scheduled_fire',
  };
}

enum GateOutcome {
  /// Device behaves normally. A test is scheduled for later.
  free,

  /// A test is owed right now. Show it.
  mustTest,

  /// A test is owed AND the clock looks like it was rolled back.
  mustTestTampered,
}

/// Side effects the gate needs, injected so tests never touch a platform channel.
class GateEffects {
  const GateEffects({
    required this.schedule,
    required this.cancel,
    required this.warn,
  });

  /// Arms the Path 2 alarm for the given instant.
  ///
  /// Returns whether the alarm is genuinely armed. Android refuses exact alarms
  /// without a user-granted permission, and a silent `false` here is the
  /// difference between "armed" and "hoping".
  final Future<bool> Function(DateTime triggerAt) schedule;

  /// Tears down any pending alarm and warning.
  final Future<void> Function() cancel;

  /// Sends the ~2 minute heads-up.
  final Future<void> Function(int minutes) warn;

  /// Does nothing. Used by tests and by first-run wiring.
  ///
  /// `static final`, not `const`: a generic tear-off is not a constant
  /// expression.
  static final inert = GateEffects(schedule: _armed, cancel: _nop, warn: _nop);

  static Future<void> _nop([Object? _]) async {}

  static Future<bool> _armed([Object? _]) async => true;
}

class GateResult {
  const GateResult(
    this.outcome, {
    required this.cooldown,
    this.triggerAt,
    this.pathTwoArmed = false,
    this.permissions = PermissionState.unknown,
  });

  final GateOutcome outcome;

  /// The evaluated cooldown, for callers that want to render remaining time.
  final Cooldown cooldown;

  /// When Path 2 is armed, or null if nothing is armed.
  final DateTime? triggerAt;

  /// Whether the scheduled alarm was genuinely accepted by the OS.
  final bool pathTwoArmed;

  /// What Android will currently allow. Drives the setup warnings in the UI.
  final PermissionState permissions;

  bool get isLocked =>
      outcome == GateOutcome.mustTest ||
      outcome == GateOutcome.mustTestTampered;

  /// Neither trigger path is currently able to interrupt.
  ///
  /// This is the failure that matters most: the app looks installed and correct,
  /// but nothing can enforce the gate. The UI must say so plainly rather than
  /// implying the device is protected.
  bool get isUnenforceable => !isLocked && !permissions.hasWorkingPath;
}

class LockGate {
  LockGate({
    required AppDatabase database,
    DateTime Function()? clock,
    GateEffects? effects,
    Future<PermissionState> Function()? permissionProbe,
  }) : _db = database,
       _now = clock ?? DateTime.now,
       _effects = effects ?? GateEffects.inert,
       _probePermission = permissionProbe;

  final AppDatabase _db;
  final DateTime Function() _now;
  final GateEffects _effects;

  /// Asks the platform what it currently permits. Injected so tests never touch
  /// a MethodChannel; defaults to the real probe.
  final Future<PermissionState> Function()? _probePermission;

  /// True once a bypass has been observed, for the settings surface (section 6).
  Future<int> bypassCount() async =>
      await _db.lockEventCount(kind: 'home_undo') +
      await _db.lockEventCount(kind: 'lock_bypass');

  /// The single decision point. Both trigger paths call exactly this.
  ///
  /// Order matters: the cooldown is read first, then the *previous* clock reading
  /// is compared, and only then is the new reading stored. Storing first would
  /// destroy the evidence of the jump we are trying to detect.
  Future<GateResult> evaluate(TriggerPath path) async {
    final now = _now();
    final lastCompleted = await _db.getLastCompletedAt();
    final lastSeen = await _db.lastSeenClock();

    final cooldown = Cooldown(lastCompletedAt: lastCompleted, now: now);
    final tampered = Cooldown.isBackwardJump(now: now, lastSeenNow: lastSeen);
    final locked = tampered || cooldown.shouldLock();

    await _db.recordClockSeen(now);

    // Ask the OS what it will actually permit. On a channel that is not
    // connected (tests) this reports `unknown`, which is treated as "no claim".
    final permissions =
        await (_probePermission ?? LockChannel.permissionStatus)();

    if (locked) {
      await _db.logLockEvent(
        kind: tampered ? 'clock_rollback' : path.label,
        at: now,
      );
      // Nothing pending matters any more; a test is owed now.
      await _effects.cancel();
      return GateResult(
        tampered ? GateOutcome.mustTestTampered : GateOutcome.mustTest,
        cooldown: cooldown,
        permissions: permissions,
      );
    }

    // Free. Keep Path 2 armed for the moment the window closes.
    final triggerAt = cooldown.nextTriggerAt;
    if (triggerAt == null) {
      await _effects.cancel();
      return GateResult(
        GateOutcome.free,
        cooldown: cooldown,
        permissions: permissions,
      );
    }

    // NOTE: no `_effects.warn(...)` call here.
    //
    // The 2-minute heads-up is scheduled natively by LockAlarm.schedule() for
    // exactly triggerAt - kGraceMinutes. Sending one from here fired it the
    // instant the app was opened, so every session produced a spurious
    // "test due shortly" notification regardless of how far away the test
    // actually was. The scheduled warning is the only correct source.
    final armed = await _effects.schedule(triggerAt);
    return GateResult(
      GateOutcome.free,
      cooldown: cooldown,
      triggerAt: triggerAt,
      pathTwoArmed: armed,
      permissions: permissions,
    );
  }
}

/// Matches the native WARN_LEAD_MS in LockAlarm.kt. Kept as a named constant so
/// the two sides are visibly the same number.
const kGraceMinutes = 2;
