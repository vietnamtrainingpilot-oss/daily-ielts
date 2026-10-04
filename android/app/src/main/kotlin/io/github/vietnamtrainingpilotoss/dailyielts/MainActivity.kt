package io.github.vietnamtrainingpilotoss.dailyielts

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The app's normal entry point -- onboarding, dashboard, test, settings.
 *
 * It owns the single MethodChannel `daily_ielts/lock`. Every native call the app
 * makes goes through here. Per AGENTS.md section 7, no database access, no
 * grading, and no UI decisions live on the native side.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "daily_ielts/lock"
    private lateinit var lockChannel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        lockChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)

        lockChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Emits `onSessionStart` to Dart. Path 1 fires this when the
                // activity resumes, which covers unlock (as the default HOME app)
                // and ordinary cold start.
                "notifySessionStart" -> {
                    lockChannel.invokeMethod("onSessionStart", null)
                    result.success(true)
                }

                "startSchedule" -> {
                    val triggerAt = call.argument<Long>("triggerAt") ?: 0L
                    // Without SCHEDULE_EXACT_ALARM this throws. A crash here would
                    // propagate up through evaluate() and leave the app in a
                    // half-initialised state, so the failure is reported as data
                    // instead and Dart surfaces the permission prompt.
                    val armed = try {
                        LockAlarm.schedule(applicationContext, triggerAt)
                        true
                    } catch (e: SecurityException) {
                        false
                    }
                    result.success(
                        mapOf("armed" to armed, "permissions" to permissionSnapshot())
                    )
                }

                "cancelSchedule" -> {
                    LockAlarm.cancel(applicationContext)
                    result.success(true)
                }

                "permissionStatus" -> result.success(permissionSnapshot())

                "requestNotificationPermission" -> requestNotificationPermission(result)

                "openPermissionSettings" ->
                    openPermissionSettings(call.argument<String>("kind") ?: "", result)

                // The 2-minute heads-up. Deliberately not cancellable: AGENTS.md
                // section 4 -- the interrupt fires either way.
                //
                // This is the *manual* nudge used by the in-app countdown. The
                // scheduled Path 2 warning is armed natively in LockAlarm.schedule,
                // so the gate must NOT also send one on every evaluation or the
                // user gets spammed the moment they open the app. It is posted
                // only when a warning is genuinely imminent.
                "sendGraceWarning" -> {
                    val minutes = call.argument<Int>("minutes") ?: 2
                    if (minutes > kManualWarnThresholdMinutes) {
                        result.success(false); return@setMethodCallHandler
                    }
                    LockAlarm.notify(
                        applicationContext,
                        LockAlarm.NOTIFY_WARN_ID,
                        "Daily test due shortly",
                        "Your daily IELTS test becomes due in about $minutes minute(s).",
                        fullScreen = false
                    )
                    result.success(true)
                }

                "openHomeSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_HOME_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(true)
                }

                // True when this activity is the resolved HOME app. Dart compares
                // this against its last known value to detect an undone bypass.
                "isDefaultHome" -> result.success(isDefaultHome())

                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Path 1's moment of truth. Dart decides whether a test is due; this only
        // announces that the session resumed.
        if (::lockChannel.isInitialized) {
            lockChannel.invokeMethod("onSessionStart", null)
        }
    }

    // -----------------------------------------------------------------------
    // Permissions
    //
    // Android silently downgrades this app without these, and the failure looks
    // like "the gate just doesn't work" rather than "a permission is missing":
    //
    //   POST_NOTIFICATIONS (13+)  every notify() call is dropped on the floor.
    //   USE_FULL_SCREEN_INTENT    Path 2 degrades to a heads-up notification,
    //                             which the user can swipe away.
    //   SCHEDULE_EXACT_ALARM      setAlarmClock throws SecurityException, which
    //                             in practice means Path 2 never arms at all.
    //
    // None of them can be silently relied on, so all three are surfaced in Dart
    // and the user is walked to the relevant settings screen.
    // -----------------------------------------------------------------------

    /** True when notifications will actually be displayed. */
    private fun notificationsGranted(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            NotificationManagerCompat.from(this).areNotificationsEnabled()
        }

    /** True when a full-screen intent is permitted (Android 14+ uses a toggle). */
    private fun fullScreenIntentGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val nm = getSystemService(NotificationManager::class.java)
        return nm.canUseFullScreenIntent()
    }

    /** True when exact alarms may be scheduled (Android 12+ user toggle). */
    private fun exactAlarmGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = getSystemService(AlarmManager::class.java)
        return am.canScheduleExactAlarms()
    }

    /** True when this activity is the resolved HOME app. */
    private fun isDefaultHome(): Boolean {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val resolved = packageManager.resolveActivity(intent, 0)
        return resolved?.activityInfo?.packageName == packageName
    }

    private fun permissionSnapshot(): Map<String, Any> = mapOf(
        "notifications" to notificationsGranted(),
        "fullScreenIntent" to fullScreenIntentGranted(),
        "exactAlarm" to exactAlarmGranted(),
        "isDefaultHome" to isDefaultHome()
    )

    /** Asks for POST_NOTIFICATIONS. No-op below Android 13. */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(permissionSnapshot()); return
        }
        if (ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(permissionSnapshot()); return
        }
        // askNotificationPermission is the API 33 native path; ActivityCompat
        // keeps one code path across versions.
        ActivityCompat.requestPermissions(
            this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), kReqNotifications
        )
        // The real answer arrives via onRequestPermissionsResult; report current
        // state now so Dart is never blocked on the dialog.
        result.success(permissionSnapshot())
    }

    /**
     * Opens the specific settings screen for [kind]: `notifications`,
     * `fullScreenIntent`, or `exactAlarm`. Each is a different screen, and sending
     * the user to the wrong one wastes the trip.
     */
    private fun openPermissionSettings(kind: String, result: MethodChannel.Result) {
        val intent = when (kind) {
            "notifications" -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)

            "fullScreenIntent" ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
                        .setData(Uri.fromParts("package", packageName, null))
                } else {
                    null
                }

            "exactAlarm" ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                        .setData(Uri.fromParts("package", packageName, null))
                } else {
                    null
                }

            else -> null
        }

        if (intent == null) {
            // Not a screen this OS version has. Nothing to fix.
            result.success(false); return
        }
        try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            result.success(true)
        } catch (e: android.content.ActivityNotFoundException) {
            // Some OEM builds omit the screen. Fall back to app details so the
            // user still lands somewhere useful instead of crashing.
            try {
                startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        .setData(Uri.fromParts("package", packageName, null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                result.success(true)
            } catch (_: android.content.ActivityNotFoundException) {
                result.success(false)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == kReqNotifications && ::lockChannel.isInitialized) {
            lockChannel.invokeMethod("onPermissionsChanged", permissionSnapshot())
        }
    }

    private companion object {
        const val kReqNotifications = 9201

        /**
         * The scheduled Path 2 warning is armed by LockAlarm.schedule itself, so
         * any `sendGraceWarning` above this many minutes out is a bug rather than
         * a notice -- it would spam the user on every app open. Refuse it.
         */
        const val kManualWarnThresholdMinutes = 5
    }
}