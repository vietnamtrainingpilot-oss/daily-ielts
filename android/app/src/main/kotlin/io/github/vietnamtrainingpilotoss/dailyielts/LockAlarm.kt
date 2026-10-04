package io.github.vietnamtrainingpilotoss.dailyielts

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Path 2 of the lock: a scheduled alarm that fires at exactly
 * `lastCompletedAt + 24h`, independent of any unlock event.
 *
 * Uses AlarmManager.setAlarmClock rather than setExact because setAlarmClock is
 * the one mode Android explicitly exempts from Doze and battery throttling -- the
 * same exemption real alarm-clock apps rely on. setExact would be silently
 * deferred under Doze and the gate would under-fire.
 *
 * AGENTS.md section 3: this path and the launcher path (Path 1) are
 * complementary. Neither replaces the other.
 */
class LockAlarm {
    companion object {
        const val EXTRA_TRIGGER_AT = "trigger_at"
        const val ACTION_FIRE = "io.github.vietnamtrainingpilotoss.dailyielts.FIRE_LOCK"
        const val ACTION_WARN = "io.github.vietnamtrainingpilotoss.dailyielts.WARN_LOCK"

        const val CHANNEL_ID = "daily_ielts_lock"
        const val NOTIFY_WARN_ID = 4201
        const val NOTIFY_FIRE_ID = 4202

        /**
         * Marks the Intent LockActivity is launched with as the Path 2 interrupt
         * rather than an ordinary session start, so Dart can label the lock event
         * `scheduled_fire` instead of `session_start`.
         */
        const val EXTRA_FROM_ALARM = "from_alarm"

        private const val REQ_WARN_ACTIVITY = 2000
        private const val REQ_FIRE_ACTIVITY = 2001

        /** AGENTS.md section 4: warn ~2 minutes out. Does not cancel anything. */
        const val WARN_LEAD_MS = 2 * 60 * 1000L

        private const val PREFS = "daily_ielts_alarm"
        private const val PREF_TRIGGER_AT = "trigger_at"

        fun channelId(): String = CHANNEL_ID

        /**
         * The armed trigger instant, persisted so [BootReceiver] can re-arm after
         * a reboot or a clock change.
         *
         * BOOT_COMPLETED and TIME_SET broadcasts carry no custom extras, so the
         * instant cannot ride along in the Intent -- it has to survive in storage.
         */
        private fun prefs(context: Context) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun persistedTriggerAt(context: Context): Long =
            prefs(context).getLong(PREF_TRIGGER_AT, 0L)

        /**
         * Schedule the interrupt for [triggerAtMillis] (epoch millis).
         * Also schedules the grace warning at triggerAt - WARN_LEAD_MS.
         */
        fun schedule(context: Context, triggerAtMillis: Long) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            ensureChannel(context)

            prefs(context).edit().putLong(PREF_TRIGGER_AT, triggerAtMillis).apply()

            val firePending = PendingIntent.getBroadcast(
                context, 1001,
                Intent(context, LockAlarmReceiver::class.java).apply {
                    action = ACTION_FIRE
                    putExtra(EXTRA_TRIGGER_AT, triggerAtMillis)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val showAt = AlarmManager.AlarmClockInfo(triggerAtMillis, firePending)
            am.setAlarmClock(showAt, firePending)

            // Grace warning. Fires whether or not the user is mid-use, purely so
            // the interrupt is never a blind surprise.
            val warnPending = PendingIntent.getBroadcast(
                context, 1002,
                Intent(context, LockAlarmReceiver::class.java).apply {
                    action = ACTION_WARN
                    putExtra(EXTRA_TRIGGER_AT, triggerAtMillis)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            am.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                triggerAtMillis - WARN_LEAD_MS,
                warnPending
            )
        }

        fun cancel(context: Context) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            cancel(context, ACTION_FIRE, 1001)
            cancel(context, ACTION_WARN, 1002)
            prefs(context).edit().remove(PREF_TRIGGER_AT).apply()
        }

        private fun cancel(context: Context, action: String, requestCode: Int) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.cancel(
                PendingIntent.getBroadcast(
                    context, requestCode,
                    Intent(context, LockAlarmReceiver::class.java).apply { this.action = action },
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Daily test reminder",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Warns you shortly before the daily test becomes due"
                enableVibration(true)
            }
            nm.createNotificationChannel(ch)
        }

        /**
         * Posts the Path 2 warning or the Path 2 interrupt.
         *
         * [fromAlarm] marks the launch as the scheduled interrupt so
         * LockActivity announces `onScheduledFire` instead of a session start.
         * It also selects a distinct PendingIntent request code: the warning and
         * the interrupt are separate launches, and sharing one request code let
         * FLAG_UPDATE_CURRENT rewrite one launch's extras from the other, so a
         * later warning would silently strip the interrupt marker.
         */
        fun notify(
            context: Context,
            id: Int,
            title: String,
            text: String,
            fullScreen: Boolean,
            fromAlarm: Boolean = false
        ) {
            ensureChannel(context)
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val pi = PendingIntent.getActivity(
                context, if (fromAlarm) REQ_FIRE_ACTIVITY else REQ_WARN_ACTIVITY,
                Intent(context, LockActivity::class.java).apply {
                    if (fromAlarm) putExtra(EXTRA_FROM_ALARM, true)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val b = Notification.Builder(context, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentIntent(pi)
                .setAutoCancel(false)
                .setOngoing(true)
            if (fullScreen) {
                b.setFullScreenIntent(pi, true)
                b.setCategory(Notification.CATEGORY_ALARM)
                b.setPriority(Notification.PRIORITY_MAX)
            }
            nm.notify(id, b.build())
        }

        }
}

class LockAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            LockAlarm.ACTION_WARN -> {
                LockAlarm.notify(
                    context,
                    LockAlarm.NOTIFY_WARN_ID,
                    "Daily test due shortly",
                    "Your daily IELTS test becomes due in about 2 minutes.",
                    fullScreen = false
                )
            }
            LockAlarm.ACTION_FIRE -> {
                // AGENTS.md section 3 requires a full-screen intent here.
                //
                // This deliberately does NOT call startActivity(): from Android 10
                // onward a BroadcastReceiver may not launch an activity when the
                // app is in the background, which is precisely the case this
                // exists for. A full-screen-intent notification is the sanctioned
                // route and is the same mechanism incoming calls use.
                LockAlarm.notify(
                    context,
                    LockAlarm.NOTIFY_FIRE_ID,
                    "Your daily IELTS test is due",
                    "Complete the test to continue using this device.",
                    fullScreen = true,
                    fromAlarm = true
                )
            }
        }
    }
}

/** Re-arms the scheduled alarm after reboot or a clock/timezone change. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Read the instant from storage, NOT from the broadcast Intent:
        // BOOT_COMPLETED and TIME_SET carry no custom extras, so reading
        // EXTRA_TRIGGER_AT here always yields 0 and the alarm was never re-armed.
        val triggerAt = LockAlarm.persistedTriggerAt(context)
        if (triggerAt <= 0L) return

        // Re-arm only if the trigger is still in the future. A trigger instant
        // that already passed while the device was off is handled by Path 1 on
        // the next unlock; the alarm itself has nothing left to do.
        if (triggerAt > System.currentTimeMillis()) {
            LockAlarm.schedule(context, triggerAt)
        } else {
            LockAlarm.cancel(context)
        }
    }
}