/// The 24h cooldown rule, isolated behind an injectable clock.
///
/// AGENTS.md section 9: time-based behaviour is tested through this, never against
/// the real system clock. No test sleeps for 24 hours.
library;

class Cooldown {
  Cooldown({required this.lastCompletedAt, required this.now});

  /// Epoch time of the last completed test, or null if none has ever been done.
  final DateTime? lastCompletedAt;

  /// Current time, injected. Every check reads this rather than DateTime.now().
  final DateTime now;

  static const window = Duration(hours: 24);

  /// True once 24h have elapsed and a test is owed.
  bool get isExpired {
    final last = lastCompletedAt;
    if (last == null) return true; // never tested -> immediately due
    return now.difference(last) >= window;
  }

  /// Time remaining in the cooldown, or null when already expired.
  Duration? get remaining {
    final last = lastCompletedAt;
    if (last == null) return null;
    final next = last.add(window);
    if (!now.isBefore(next)) return null;
    return next.difference(now);
  }

  /// When the next scheduled interrupt should fire, or null if nothing is owed.
  DateTime? get nextTriggerAt {
    final last = lastCompletedAt;
    if (last == null) return null;
    final next = last.add(window);
    return next.isAfter(now) ? next : null;
  }

  /// AGENTS.md section 5: a backward clock jump is treated as EXPIRED. Fail
  /// toward "make them do it", never toward "let them skip it".
  ///
  /// [lastSeenNow] is the previously observed wall-clock reading.
  static bool isBackwardJump({required DateTime now, DateTime? lastSeenNow}) {
    if (lastSeenNow == null) return false;
    return now.isBefore(lastSeenNow);
  }

  /// The effective decision for Path 1.
  ///
  /// A detected backward clock jump forces the lock regardless of what the
  /// cooldown arithmetic says, because that arithmetic is exactly what a
  /// rollback defeats.
  bool shouldLock({DateTime? lastSeenNow}) {
    if (isBackwardJump(now: now, lastSeenNow: lastSeenNow)) return true;
    return isExpired;
  }
}
