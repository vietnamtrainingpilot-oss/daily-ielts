import 'package:flutter_test/flutter_test.dart';
import 'package:daily_ielts/cooldown.dart';

void main() {
  // A fixed reference instant. No test here sleeps, and none reads the real
  // system clock -- AGENTS.md section 9.
  final lastCompleted = DateTime.utc(2026, 10, 1, 9, 0, 0);

  group('cooldown window', () {
    test('immediately after completing a test, nothing is owed', () {
      final c = Cooldown(
        lastCompletedAt: lastCompleted,
        now: lastCompleted.add(const Duration(minutes: 1)),
      );
      expect(c.isExpired, isFalse);
      expect(c.shouldLock(), isFalse);
    });

    test(
      'at 23h59m nothing is owed -- outside the window the device is normal',
      () {
        final c = Cooldown(
          lastCompletedAt: lastCompleted,
          now: lastCompleted.add(const Duration(hours: 23, minutes: 59)),
        );
        expect(c.isExpired, isFalse);
        expect(c.shouldLock(), isFalse);
      },
    );

    test('at exactly 24h the test is owed', () {
      final c = Cooldown(
        lastCompletedAt: lastCompleted,
        now: lastCompleted.add(const Duration(hours: 24)),
      );
      expect(c.isExpired, isTrue);
      expect(c.shouldLock(), isTrue);
    });

    test('past 24h the test is still owed', () {
      final c = Cooldown(
        lastCompletedAt: lastCompleted,
        now: lastCompleted.add(const Duration(hours: 30)),
      );
      expect(c.isExpired, isTrue);
    });

    test('a user who has never completed a test is immediately due', () {
      final c = Cooldown(lastCompletedAt: null, now: lastCompleted);
      expect(c.isExpired, isTrue);
      expect(c.shouldLock(), isTrue);
    });
  });

  group('remaining time', () {
    test('counts down inside the window', () {
      final c = Cooldown(
        lastCompletedAt: lastCompleted,
        now: lastCompleted.add(const Duration(hours: 20)),
      );
      expect(c.remaining, const Duration(hours: 4));
    });

    test('is null once expired', () {
      final c = Cooldown(
        lastCompletedAt: lastCompleted,
        now: lastCompleted.add(const Duration(hours: 25)),
      );
      expect(c.remaining, isNull);
    });
  });

  group('scheduled trigger instant (Path 2)', () {
    test('is exactly lastCompletedAt + 24h', () {
      final c = Cooldown(
        lastCompletedAt: lastCompleted,
        now: lastCompleted.add(const Duration(hours: 3)),
      );
      expect(c.nextTriggerAt, lastCompleted.add(const Duration(hours: 24)));
    });

    test('is null when nothing is owed', () {
      final c = Cooldown(
        lastCompletedAt: lastCompleted,
        now: lastCompleted.add(const Duration(hours: 25)),
      );
      expect(c.nextTriggerAt, isNull);
    });
  });

  group('clock tampering -- AGENTS.md section 5', () {
    test('a backward jump is detected', () {
      expect(
        Cooldown.isBackwardJump(
          now: lastCompleted.subtract(const Duration(hours: 5)),
          lastSeenNow: lastCompleted,
        ),
        isTrue,
      );
    });

    test('normal forward progress is not a jump', () {
      expect(
        Cooldown.isBackwardJump(
          now: lastCompleted.add(const Duration(minutes: 1)),
          lastSeenNow: lastCompleted,
        ),
        isFalse,
      );
    });

    test('a backward jump forces the lock even though arithmetic says otherwise', () {
      // The user completed a test, then rolled the clock back so the cooldown
      // arithmetic reports "not expired". The tamper rule must override it and
      // fail toward showing the test.
      final rolledBackNow = lastCompleted.subtract(const Duration(hours: 5));
      final c = Cooldown(lastCompletedAt: lastCompleted, now: rolledBackNow);

      // Arithmetic alone would let them skip:
      expect(c.isExpired, isFalse);

      // With the prior reading supplied, the lock is forced anyway:
      expect(c.shouldLock(lastSeenNow: lastCompleted), isTrue);
    });

    test('no prior reading means no tamper claim', () {
      final c = Cooldown(
        lastCompletedAt: lastCompleted,
        now: lastCompleted.add(const Duration(hours: 1)),
      );
      expect(c.shouldLock(lastSeenNow: null), isFalse);
    });
  });
}
