import 'package:flutter/services.dart';

/// What Android will and will not actually do right now.
///
/// Android degrades this app silently rather than erroring: notifications vanish,
/// the full-screen intent becomes a swipeable heads-up, and `setAlarmClock` throws
/// inside a background receiver where nobody sees it. Each flag here is the
/// difference between "the gate is armed" and "the gate silently is not".
class PermissionState {
  const PermissionState({
    required this.notifications,
    required this.fullScreenIntent,
    required this.exactAlarm,
    required this.isDefaultHome,
  });

  /// Android 13+ drops every notification without this.
  final bool notifications;

  /// Android 14+ moved full-screen intent to a user toggle.
  final bool fullScreenIntent;

  /// Android 12+ can revoke exact alarms; `setAlarmClock` throws without it.
  final bool exactAlarm;

  /// Whether this app is currently the resolved HOME launcher.
  final bool isDefaultHome;

  /// True when Path 2 can actually fire. Path 1 is independent and unaffected.
  bool get pathTwoArmed => notifications && fullScreenIntent && exactAlarm;

  /// The gate needs at least one working path to be trustworthy.
  bool get hasWorkingPath => pathTwoArmed || isDefaultHome;

  static const unknown = PermissionState(
    notifications: false,
    fullScreenIntent: false,
    exactAlarm: false,
    isDefaultHome: false,
  );

  factory PermissionState.fromMap(Map<dynamic, dynamic> m) => PermissionState(
    notifications: m['notifications'] as bool? ?? false,
    fullScreenIntent: m['fullScreenIntent'] as bool? ?? false,
    exactAlarm: m['exactAlarm'] as bool? ?? false,
    isDefaultHome: m['isDefaultHome'] as bool? ?? false,
  );

  @override
  String toString() =>
      'PermissionState(notif: $notifications, '
      'fsi: $fullScreenIntent, alarm: $exactAlarm, home: $isDefaultHome)';
}

/// The single Flutter -> native boundary. AGENTS.md section 7.
///
/// Commands travel one way through [invoke]; native events arrive on
/// [onSessionStart] and [onScheduledFire]. Database access, grading, and UI
/// decisions deliberately stay in Dart.
class LockChannel {
  static const _channel = MethodChannel('daily_ielts/lock');

  /// Fired by native whenever the session resumes -- which, when this app is the
  /// default HOME launcher, is what an unlock looks like. Path 1.
  static Future<void> Function()? onSessionStart;

  /// Fired when the scheduled alarm interrupts, for a device left unlocked
  /// straight through the 24h mark. Path 2.
  static Future<void> Function()? onScheduledFire;

  /// Fired when the user answers the notification permission dialog.
  static void Function(PermissionState)? onPermissionsChanged;

  static void _listen() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onSessionStart':
          await onSessionStart?.call();
        case 'onScheduledFire':
          await onScheduledFire?.call();
        case 'onPermissionsChanged':
          final arg = call.arguments;
          if (arg is Map) {
            onPermissionsChanged?.call(PermissionState.fromMap(arg));
          }
      }
    });
  }

  static void install() => _listen();

  /// Arms Path 2 for exactly [triggerAt]. Native uses
  /// AlarmManager.setAlarmClock, the mode Android exempts from Doze throttling.
  ///
  /// Returns false when Android refused (usually SCHEDULE_EXACT_ALARM). The gate
  /// must treat that as "Path 2 is not available" rather than assuming success.
  static Future<bool> startSchedule(DateTime triggerAt) async {
    try {
      final res = await _channel.invokeMethod<dynamic>('startSchedule', {
        'triggerAt': triggerAt.millisecondsSinceEpoch,
      });
      if (res is Map) return res['armed'] as bool? ?? false;
      return res as bool? ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> cancelSchedule() =>
      _channel.invokeMethod('cancelSchedule');

  static Future<PermissionState> permissionStatus() async {
    try {
      final m = await _channel.invokeMethod<dynamic>('permissionStatus');
      if (m is Map) return PermissionState.fromMap(m);
    } on PlatformException {
      // Non-Android (tests, Windows): report "unknown", never throw into the gate.
    } on MissingPluginException {
      // No native handler at all. Same answer as a refusal.
    }
    return PermissionState.unknown;
  }

  static Future<PermissionState> requestNotificationPermission() async {
    try {
      final m = await _channel.invokeMethod<dynamic>(
        'requestNotificationPermission',
      );
      if (m is Map) return PermissionState.fromMap(m);
    } on PlatformException {
      // Fall through to the plain read below.
    } on MissingPluginException {
      // Fall through to the plain read below.
    }
    return permissionStatus();
  }

  /// Opens the settings screen for [kind]: `notifications`, `fullScreenIntent`,
  /// or `exactAlarm`.
  static Future<bool> openPermissionSettings(String kind) async {
    try {
      return await _channel.invokeMethod<bool>('openPermissionSettings', {
            'kind': kind,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// True when this app is the resolved HOME app. Compared against the last
  /// known value to detect an undone bypass.
  static Future<bool> isDefaultHome() async {
    try {
      return await _channel.invokeMethod<bool>('isDefaultHome') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The ~2 minute heads-up before a forced interrupt. Advisory only -- it does
  /// not and cannot stop the interrupt.
  ///
  /// Native refuses anything beyond a few minutes out, because the scheduled Path
  /// 2 warning is armed independently; calling this on every evaluation would
  /// spam the user on every app open.
  static Future<bool> sendGraceWarning({int minutes = 2}) async {
    try {
      return await _channel.invokeMethod<bool>('sendGraceWarning', {
            'minutes': minutes,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the OS screen where the default home app is changed. Surfacing this
  /// is deliberate; blocking it is out of scope (AGENTS.md section 6).
  static Future<void> openHomeSettings() =>
      _channel.invokeMethod('openHomeSettings');

  /// Which launch path brought this process up, as reported by native.
  ///
  /// Native reads its own launch Intent and answers with `scheduled_fire` or
  /// `session_start`. This is a read, not a decision: Dart still evaluates the
  /// gate once and records the path it was told about.
  ///
  /// Returns null when the query is unavailable -- tests, non-Android, or a
  /// platform that has not implemented it -- so the caller falls back instead of
  /// throwing into the gate. See AGENTS.md section 7.
  ///
  /// TESTING: inject a reader, do not let this hit the channel inside
  /// `testWidgets`. An unregistered MethodChannel call in a fake-async zone never
  /// completes, because the MissingPluginException reply is delivered outside the
  /// fake clock -- so `await` on it hangs rather than throwing, and any boot path
  /// that awaits this stalls forever. That is exactly why `DailyIeltsApp` takes an
  /// injectable reader alongside its injectable clock and permission probe.
  static Future<String?> launchPath() async {
    try {
      return await _channel.invokeMethod<String>('launchPath');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Native asking Dart to re-run the Path 1 check. Exposed so the Android side
  /// can nudge a re-evaluation on resume.
  static Future<void> notifySessionStart() =>
      _channel.invokeMethod('notifySessionStart');
}
