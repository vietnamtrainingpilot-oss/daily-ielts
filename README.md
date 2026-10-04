# Daily IELTS

An offline Android app that gates your phone behind one short IELTS test every 24
hours. Once 24 hours pass since your last completed test, the next unlock or logon
blocks normal use until you finish the test. **Outside that window your phone behaves
completely normally** — this is a once-a-day gate, not a continuous block.

Fully offline. No accounts, no backend, no tracking, no network calls.

## Status

Honest current state, because it matters before you install this on a real phone:

- The Dart logic — cooldown rule, grading, persistence, routing — is covered by an
  automated suite (`flutter test`, 51 tests) and passes.
- A release APK builds cleanly and its package identity, launcher icons, and
  manifest are verified.
- **It has not yet been verified on a physical device.** The Android alarm and
  full-screen wiring compiles but has not been exercised on real hardware. See
  the caveat below before relying on it.

## What it does

- **The 24-hour rule.** A single decision point (`lib/lock_gate.dart`) is consulted by
  both trigger paths.
- **Two trigger paths, one outcome.** On unlock/logon, *and* via a scheduled alarm for
  a phone left unlocked straight through the 24-hour mark.
- **Grace warning.** Roughly two minutes before a scheduled interrupt, you get a
  notification. The interrupt still happens — it is a heads-up, not an escape hatch.
- **Clock-tamper detection.** If the local clock jumps backward, the cooldown is
  treated as expired and the test is required.
- **Bypass visibility, not enforcement.** Anyone who installs this knows how to defeat
  it. Rather than pretend otherwise, every bypass is logged and shown as a visible
  count on the dashboard.
- **Local history.** Completed tests, scores, and lock events are stored on-device in
  sqflite and never leave the phone.

## Install

Download the `app-release.apk` from the repository's Releases page, then on your phone
open it and allow installs from your file manager.

You will need to grant it these permissions for the gate to actually work:

- **Set as default launcher** — this is how the app knows you unlocked the phone.
- **Notifications** — for the pre-interrupt warning and the interrupt itself.
- **Exact alarm** — so the scheduled path fires on time.

The app tells you when any of these are missing and shows an explicit "not enforcing"
state rather than silently failing.

> Because it registers itself as a launcher and can present a full-screen interrupt,
> it will not pass Google Play policy review in its current form. It is distributed as
> a sideloaded APK. Uninstalling is a normal `adb uninstall` or a long-press on the
> icon; your local history is removed with it.

## Build from source

Requires Flutter 3.47.5 / Dart 3.13.4 and a JDK 17 Android toolchain.

```powershell
flutter pub get
flutter test
flutter build apk --release
```

The output lands at `build/app/outputs/flutter-apk/app-release.apk`.

### Release signing

Release signing is read from `android/key.properties`, which is git-ignored and never
committed. The keystore is expected to live outside the repository entirely.

```
# android/key.properties  (git-ignored -- never commit this)
storeFile=D:/toolchain/keys/dailyielts-upload.jks
storePassword=...
keyAlias=dailyielts
keyPassword=...
```

If that file is absent the release build falls back to the debug key so the project
still compiles. **A debug-signed build is for local testing only and must never be
published** — Android refuses to upgrade a debug-signed app with a release-signed one,
so anyone who installed it would have to uninstall and lose their history.

Generate a keystore once, and keep it backed up somewhere you will not lose it:

```powershell
& D:\toolchain\jdk\bin\keytool.exe -genkeypair -v `
  -keystore D:\toolchain\keys\dailyielts-upload.jks `
  -alias dailyielts -keyalg RSA -keysize 4096 -validity 10000 -storetype PKCS12
```

Losing this key permanently strands every installed copy. Back it up before you
publish.

### Signing certificate (permanent identity)

Every release must be signed with the same certificate or Android will refuse the
update. This is the fingerprint of the one you should expect:

```
SHA-256: 92f005663c664cf02d9c340da896c0f7abc3db00ceb8363436c94d4b1b4bd966
DN: CN=Nguyen, OU=Personal, O=Personal, L=Personal, ST=Personal, C=VN
```

Verify any APK before you trust it. `apksigner` is not on `PATH`, so this finds the
newest build-tools first:

```powershell
$bt = Get-ChildItem "$env:ANDROID_SDK_ROOT\build-tools" -Directory |
      Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
& "$($bt.FullName)\apksigner.bat" verify --print-certs .\build\app\outputs\flutter-apk\app-release.apk
```

If that ever prints `CN=Android Debug`, you are looking at a throwaway local build —
do not distribute it.

## Repo layout

| Path | What |
|---|---|
| `lib/cooldown.dart` | The 24h rule, behind an injectable clock |
| `lib/lock_gate.dart` | The single decision point both trigger paths use |
| `lib/app_database.dart` | sqflite: history, lock events, question bank |
| `lib/lock_channel.dart` | The one `daily_ielts/lock` MethodChannel |
| `lib/main.dart` | Dashboard, test screen, onboarding, routing |
| `android/.../MainActivity.kt` | Channel owner; emits `onSessionStart` |
| `android/.../LockAlarm.kt` | Path 2: `setAlarmClock`, warning, boot re-arm |
| `android/.../LockActivity.kt` | Full-screen target; no logic |

Native package: `io.github.vietnamtrainingpilotoss.dailyielts`.

## Further reading

- `AGENTS.md` — binding architecture and verification rules for contributors
- `DESIGN.md` — the visual identity and design tokens (single source of truth)
- `TESTING.md` — the automated suite **and** the manual device test plan