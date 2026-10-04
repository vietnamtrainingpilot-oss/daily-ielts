package io.github.vietnamtrainingpilotoss.dailyielts

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

/**
 * The activity a Path 2 full-screen intent lands on.
 *
 * It deliberately has NO MethodChannel handler and asks nothing of Dart. This
 * app's whole decision surface lives in Dart behind `daily_ielts/lock`, and
 * MainActivity is the single owner of that channel -- a second handler here on
 * the same channel name would be a second, divergent implementation of the gate.
 *
 * All this activity does is present itself over the lock screen. Flutter boots
 * the same `main()` as everywhere else, the gate evaluates, and Dart routes to
 * the test screen on its own.
 */
class LockActivity : FlutterActivity() {
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