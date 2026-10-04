# Testing Guide — Daily IELTS Phase 1 (Android)

Two tiers. Tier 1 is automated and runs in ~4 seconds. Tier 2 is manual device
testing, and it is the tier that actually matters — **the Android gate has never
been run on a device.** Everything in Tier 1 proves the Dart decision logic; only
Tier 2 proves the alarm actually fires.

---

## 0. Environment

Every Flutter/Gradle command in this repo needs these. They are not persisted in
your shell profile, so set them per session:

```powershell
$env:Path = "D:\toolchain\jdk\bin;D:\toolchain\flutter\bin;" + $env:Path
$env:ANDROID_SDK_ROOT = "D:\toolchain\android-sdk"
$env:JAVA_HOME = "D:\toolchain\jdk"
$env:PUB_CACHE = "D:\toolchain\pub-cache"
$env:GRADLE_USER_HOME = "D:\toolchain\gradle-home"
cd D:\Portfolio\daily-ielts
```

`GRADLE_USER_HOME` is set persistently at user scope via `setx`, so new shells pick
it up automatically. It is set **only** to keep the Gradle cache off C:, which had
fallen to 2.5 GB free. Removing it silently restores the default
`C:\Users\Admin\.gradle` and will start refilling C:. The cache is now ~3.6 GB on
D: and is repopulated there.

Check it took:

```powershell
flutter doctor -v     # Flutter + Android toolchain must both be green
```

If `flutter doctor` reports `cmdline-tools component is missing` or Android
licenses unaccepted, re-run the SDK install from
`D:\Portfolio\docs\superpowers\specs\2026-10-01-google-toolchain-and-prompts.md`.

---

## Tier 1 — Automated (41 tests, all passing)

```powershell
dart analyze lib test    # expect: No issues found!
flutter test             # expect: All tests passed!  (41)
flutter build apk --debug
```

Per AGENTS.md §9 a change is not done until all three hold.

### What each file actually proves

| File | Proves |
|---|---|
| `test/cooldown_test.dart` | The 24h arithmetic. Free below 24h, locked at exactly 24h, never-tested is immediately due, and a backward clock jump forces a lock even when the arithmetic says "not due". |
| `test/app_database_test.dart` | Persistence survives a process kill, a completed test resets the window in one transaction, bypass events are recorded but never grant extra time, and the question bank seeds correctly. |
| `test/lock_gate_test.dart` | **The convergence test.** Path 1 and Path 2 return the same verdict; the alarm is armed for exactly `lastCompletedAt + 24h`; the 2-minute warning is sent; and clock evidence is read *before* it is overwritten (which is what makes tamper detection work at all). |
| `test/widget_test.dart` | Routing. Expired shows the test screen, inside the window shows the dashboard with a countdown, finishing the test releases the lock, and a rolled-back clock still forces the test with the explanation on screen. |

### Running one file or one test

```powershell
flutter test test/lock_gate_test.dart
flutter test test/lock_gate_test.dart --plain-name "backward clock jump forces the lock"
```

### No test sleeps for 24 hours

Time is injected everywhere (`LockGate(clock: ...)`, `DailyIeltsApp(clock: ...)`).
`test/lock_gate_test.dart` advances a `clockNow` variable explicitly. If you add
time-based behaviour, inject the clock the same way — do not read `DateTime.now()`
in a test.

### If a DB-backed widget test hangs

`test/widget_test.dart` uses `databaseFactoryFfiNoIsolate` deliberately. The
isolate-backed factory does real cross-isolate I/O that cannot complete inside the
widget tester's fake-async zone, and the test will sit until the 10-minute timeout.

Also: do not use `pumpAndSettle` there. The loading state is a
`CircularProgressIndicator`, which animates forever, so `pumpAndSettle` always
times out. `pumpApp()` uses a bounded loop instead.

---

## Tier 2 — Manual device testing (NOT YET DONE)

### Install

```powershell
adb devices
flutter build apk --debug
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

### Phone setup (do this once)

1. Settings → About phone → tap **Build number** 7 times → Developer options unlock.
2. Developer options → **USB debugging** on.
3. Connect by USB, accept the "Allow USB debugging" prompt on the phone.
4. Confirm: `adb devices` lists your device with state `device` (not `unauthorized`).

`flutter doctor` will then list it under Connected device. Until it does, Tier 2
cannot run at all.

You can skip the USB step and use `flutter run` over WiFi, but the manual alarm
tests below need you to be able to run `adb shell`, so USB is the simpler path.

### The 24h problem

You cannot wait 24 hours to test this. You have three levers:

1. **Set the device clock forward** past the 24h mark.
2. **Set it forward, then back** — this exercises the tamper path.
3. **Change the system clock** to a time past `lastCompletedAt + 24h`.

Note that lever 1 and 2 also trip the backward-jump detector if you move the clock
backwards at any point, so the app will lock for the *tamper* reason rather than the
*expiry* reason. That is correct behaviour, but it means you cannot cleanly
observe plain expiry by fiddling with the clock alone after the fact. To observe
plain expiry, move the clock forward and leave it there.

### Test A — first launch, never tested

- Fresh install → launch → expect the **test screen**, not the dashboard.
- Expect "A test is due".
- Tap **Complete test** → expect the dashboard with a countdown.

### Test B — Path 1, unlock / session start

This is the primary path and depends on the app being the default HOME launcher.

1. Settings → Apps → Default apps → Home app → **Daily IELTS**.
2. Press Home.
3. Expect the test screen immediately on a never-completed install.
4. Complete the test, press Home again → expect the dashboard.

**If Home still opens your real launcher**, Path 1 is not active. Check
`aapt2 dump xmltree` output shows `HOME` on `MainActivity`, and re-verify with:

```powershell
adb shell cmd package resolve-activity -c android.intent.category.HOME -a android.intent.action.MAIN
```

Should resolve to `app.dailyielts.daily_ielts/.MainActivity`.

### Test C — Path 2, scheduled alarm (least verified)

1. Install, complete one test so a 24h window opens.
2. Confirm the dashboard shows a countdown and "Alarm armed for <timestamp>".
3. **Shorten the wait.** Either set the device clock forward to just past
   `lastCompletedAt + 24h`, or temporarily lower `Cooldown.window`.
4. Keep the app in the foreground or background — the point is it must fire
   *without* an unlock event.
5. Expect a **full-screen notification** that launches the test screen.

Likely failure points, in the order you should check them:

- **Nothing appears.** Android 13+ requires a runtime `POST_NOTIFICATIONS`
  grant. **This is not implemented** — expect the warning to be silently dropped.
  Grant it manually: Settings → Apps → Daily IELTS → Notifications.
- **Notification appears but is not full-screen.** Android 14+ requires the user
  to enable full-screen intents: Settings → Apps → Special app access → Full-screen
  notifications. **The app does not surface this toggle.**
- **Alarm never fires at all.** Check it is scheduled:
  ```powershell
  adb shell dumpsys alarm | Select-String -Pattern "daily_ielts" -Context 2
  ```

### Test D — reboot re-arm (recently fixed, worth confirming)

1. With an alarm armed, reboot the device.
2. Confirm the alarm is re-armed:
   ```powershell
   adb shell dumpsys alarm | Select-String -Pattern "daily_ielts"
   ```
3. Confirm the trigger instant survived in SharedPreferences:
   ```powershell
   adb shell "run-as app.dailyielts.daily_ielts cat /data/data/app.dailyielts.daily_ielts/shared_prefs/daily_ielts_alarm.xml"
   ```
   (`run-as` only works on debug builds, which this is.)

Before the fix this silently never re-armed, because `BOOT_COMPLETED` carries no
custom extras.

### Test E — clock rollback

1. Complete a test. Note the countdown.
2. Move the device clock backwards.
3. Re-enter the app → expect the test screen, with "The device clock moved
   backwards. The test is required anyway."
4. Confirm it logged:
   ```powershell
   adb shell "run-as app.dailyielts.daily_ielts sqlite3 /data/data/app.dailyielts.daily_ielts/databases/daily_ielts.db 'SELECT kind, datetime(occurred_at/1000,\"unixepoch\") FROM lock_events ORDER BY id DESC LIMIT 5;'"
   ```
   Look for `clock_rollback`.

### Test F — bypass is visible, not blocked (AGENTS.md §6)

1. While the app is set as Home, go to Settings → Default apps → Home app and
   change it back to your real launcher.
2. Nothing should stop you. That is intended.
3. Reopen the app → dashboard → "Lock bypasses on record" should read `1`.

---

## Not covered by either tier

- **Windows.** No code path is built. Blocked on host disk space, per user
  instruction.
- **The real question bank.** Three placeholder questions ship in
  `app_database.dart`. The full bank is content work.
- **Grading.** Recorded as band `0`. Phase 2, and deliberately not faked.
- **Visual fidelity.** No `DESIGN.md` exists, so the UI is unstyled placeholder
  Material. See the vault log for the AGENTS.md §8 violation this causes.