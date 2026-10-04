# Daily IELTS — Agent Rules

These rules bind every agent working in this repo (Antigravity, Antigravity CLI, or
otherwise). Read before making any change. If a task conflicts with a rule, the rule
wins and the conflict gets raised rather than silently resolved.

---

## 1. Stack

- Flutter 3.47.5 / Dart 3.13.4. Android is the primary target; Windows is written but
  not built yet (blocked on host disk space, not on code).
- `sqflite` for all persistence. `path_provider` for filesystem paths.
- Fully offline. No backend, no accounts, no sync, no hosting.
- The only permitted network call is an optional direct Gemini API call for Phase 2
  writing/speaking scoring. Never introduce a cloud dependency for anything else.

## 2. The one rule

The device is gated behind a daily IELTS test. Once every 24 hours since the last
completed test, the next unlock/logon blocks normal use until the test is done.

**Outside that 24h window the device behaves COMPLETELY NORMALLY.** This is not a
continuous block. Code that degrades normal device use inside the cooldown window is a
bug, not a feature.

## 3. Trigger architecture — two paths, one code path

Both platforms need **both** paths. They converge on one `showTest()` entry point.

**Path 1 — event driven.** On unlock / session start: if
`now - lastCompletedAt >= 24h`, call `showTest()`.
  - Android: registered as default launcher (`HOME` intent category)
  - Windows: session logon/unlock check

**Path 2 — scheduled.** An alarm / scheduled task set for exactly
`lastCompletedAt + 24h`, independent of any unlock event, for a device left unlocked
straight through the mark.
  - Android: `AlarmManager.setAlarmClock` + full-screen intent
    (`USE_FULL_SCREEN_INTENT` manifest permission; Android 14+ grants this via a user
    toggle rather than silently)
  - Windows: background service / scheduled task awaiting the trigger instant

If the machine sleeps through the trigger instant, Path 2's wait pauses and Path 1
catches it on resume. **The paths are complementary, not redundant.** Do not remove
either.

## 4. Grace warning

Roughly 2 minutes before a Path 2 interrupt fires, post a notification. The interrupt
still happens either way — the warning exists only so nobody is blindsided mid-keystroke.
Do not treat the warning as a cancellable escape hatch.

## 5. Clock tampering

If the local clock is detected jumping **backward**, treat the cooldown as **expired**
and show the test.

Fail toward "make them do it", never toward "let them skip it."

## 6. Bypass policy — visibility, not enforcement

Assume the user knows exactly how to disable this. They installed it themselves.

Log every bypass as a `LockEvent` and surface a visible count on the dashboard. **Do not
attempt to prevent the bypass.** Real tamper-resistance needs Android Device Owner
enrollment or a signed protected Windows service — both explicitly out of scope.

## 7. Flutter ↔ native boundary

All native code is reached through exactly **one** `MethodChannel`, named
`daily_ielts/lock`.

Dart → native commands:
`isCooldownExpired` · `markCompleted` · `setLauncherAsHome` · `startSchedule` ·
`cancelSchedule` · `logBypass`

Native → Dart events:
`onSessionStart` · `onScheduledFire`

**Not** on the channel: database access, grading, or UI. Those stay in Dart so the
channel stays thin enough to reason about and to test one side at a time. Do not widen
the channel surface without a reason that survives "would I test this separately?".

## 8. Design tokens

`DESIGN.md` at the repo root is the single source of truth for visual identity.

Never use a colour, spacing value, font-size, or radius that is not defined there. If a
needed value is missing, add it to `DESIGN.md` first, then use it. Do not hardcode hex
values or magic numbers in widgets.

## 9. Verification discipline

A change is not done until all three hold:

1. `dart analyze` is clean
2. `flutter test` passes
3. the relevant `flutter build` succeeds

**A build that compiles but does not demonstrably behave correctly is a failure.**
Report actual command output. Never assert success without having run it.

For time-based behaviour, tests use an **injectable clock**. Never write a test that
sleeps for 24 hours, and never test the real `DateTime.now()` directly — inject it.

## 10. Minimalism

No abstraction, config surface, or extension point that the current phase does not need.

Phase 1 explicitly does **not** need: a DI container, a repository pattern, a
state-management library beyond what Flutter ships, a migration framework, or
multi-impl interfaces.

Do not build for Phase 2. Phase 2 is gated behind explicit user approval.

## 11. Out of scope

Leaderboards/social (needs a backend, conflicts with the offline goal), bulk PDF/CSV
question import, multi-language UI, Play Store release, Windows code-signing, and any
spend of real API credits. Do not implement these unless explicitly asked.

## 12. Where things live

- App code: this repo
- Stitch exports (`DESIGN.md`, per-screen HTML/PNG): `D:\Portfolio\design\stitch-exports`
- Specs and plans: `D:\Portfolio\docs\superpowers\specs`
- Knowledge vault / decision log: `D:\Portfolio\vault`

The local history mirror writes to the app documents directory under
`Daily IELTS/history/`. It is always on, with no export button.