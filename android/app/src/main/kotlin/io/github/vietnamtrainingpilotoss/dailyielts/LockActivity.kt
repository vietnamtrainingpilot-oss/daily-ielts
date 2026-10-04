package io.github.vietnamtrainingpilotoss.dailyielts

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The activity a Path 2 full-screen intent lands on.
 *
 * It presents itself over the lock screen and answers one read-only question from
 * Dart: *why* was this launched. Dart boots the same `main()` as everywhere else,
 * so without that answer a scheduled interrupt is indistinguishable from an
 * ordinary unlock and every lock event gets recorded as `session_start`.
 *
 * It registers no decision handler. The gate, the database, and every UI choice
 * stay in Dart behind `daily_ielts/lock`; this only reads a launch Intent.
 *
 * Correcting the earlier reasoning in this file: the original comment treated
 * "having a MethodChannel here" as the hazard, which is why the launch reason was
 * never reported at all. The hazard is a second handler implementing gate logic.
 * Reading a launch reason is the opposite of that.
 */
class LockActivity : FlutterActivity() {
    private val channelName = "daily_ielts/lock"

    /**
     * Answers Dart's launch-path query.
     *
     * Recording the reason here rather than pushing a separate `onScheduledFire`
     * event is deliberate. Dart's boot evaluation and a pushed event would both
     * call `evaluate()`, and `evaluate()` writes a LockEvent every time it is
     * locked -- so pushing would double-count every interrupt. One evaluation at
     * boot, told what triggered it, is the honest version.
     *
     * AGENTS.md section 7's native -> Dart events stay declared and handled in
     * Dart. This is the one extra query added, and it is testable on the Dart side
     * by injecting a launch-path reader.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchPath" -> result.success(launchPathFor(intent))
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Show over the lock screen and stay on when the user tries to dismiss it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}

/**
 * The label Dart records for a lock event raised by this launch.
 *
 * Mirrors `TriggerPath.label` on the Dart side; kept as strings on purpose so the
 * Kotlin side holds no reference to a Dart enum.
 */
internal fun launchPathFor(intent: android.content.Intent?): String =
    if (intent?.getBooleanExtra(LockAlarm.EXTRA_FROM_ALARM, false) == true) "scheduled_fire"
    else "session_start"
