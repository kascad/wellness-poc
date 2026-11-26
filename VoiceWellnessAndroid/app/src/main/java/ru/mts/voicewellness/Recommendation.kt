package ru.mts.voicewellness

import android.Manifest
import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import java.time.ZonedDateTime

internal const val DEMO_RECOMMENDATION = "Голос звучит иначе, чем в предыдущих замерах. Если осиплость сохраняется, обсудите её с ЛОР-врачом."

internal data class Recommendation(val id: String, val reminderAt: Long?)

internal class Recommendations(private val context: Context) {
    private val preferences = context.getSharedPreferences("recommendation", Context.MODE_PRIVATE)
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)

    fun current(): Recommendation? = preferences.getString("id", null)?.let { id ->
        Recommendation(id, preferences.getLong("time", 0).takeIf { it > 0 })
    }

    fun createDemo(): Recommendation? {
        if (MeasurementStore(context).paused) return null
        current()?.let { return it }
        val id = java.util.UUID.randomUUID().toString()
        preferences.edit().putString("id", id).apply()
        return current()
    }

    fun postpone(id: String): Boolean {
        if (current()?.id != id || MeasurementStore(context).paused ||
            !notifications.areNotificationsEnabled()) return false
        cancelReminder()
        val date = ZonedDateTime.now().plusDays(1).withSecond(0).withNano(0).toInstant().toEpochMilli()
        preferences.edit().putLong("time", date).apply()
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, date, intent(REMIND, id))
        return true
    }

    fun close(id: String) {
        if (current()?.id != id) return
        cancelReminder()
        preferences.edit().remove("id").apply()
    }

    fun cancelReminder() {
        current()?.let { alarms.cancel(intent(REMIND, it.id)) }
        notifications.cancel(NOTIFICATION_ID)
        preferences.edit().remove("time").apply()
    }

    @SuppressLint("MissingPermission")
    fun deliver(id: String) {
        val entry = current()
        if (entry?.id != id || entry.reminderAt == null || MeasurementStore(context).paused) return
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        notifications.createNotificationChannel(NotificationChannel(CHANNEL, "Рекомендации", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, 9, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val card = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Голос · демо")
            .setContentText(DEMO_RECOMMENDATION)
            .setStyle(Notification.BigTextStyle().bigText(DEMO_RECOMMENDATION))
            .setContentIntent(open)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .addAction(Notification.Action.Builder(null, "Уже обратился", intent(CONSULTED, id)).build())
            .addAction(Notification.Action.Builder(null, "Позже", intent(LATER, id)).build())
            .addAction(Notification.Action.Builder(null, "Пропустить", intent(SKIP, id)).build())
            .build()
        notifications.notify(NOTIFICATION_ID, card)
        preferences.edit().remove("time").apply()
    }

    private fun intent(action: String, id: String): PendingIntent =
        PendingIntent.getBroadcast(context, 0, Intent(context, RecommendationReceiver::class.java)
            .setAction(action).putExtra("recommendation", id),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    companion object {
        const val REMIND = "ru.mts.voicewellness.REMIND"
        const val LATER = "ru.mts.voicewellness.LATER"
        const val CONSULTED = "ru.mts.voicewellness.CONSULTED"
        const val SKIP = "ru.mts.voicewellness.SKIP"
        private const val CHANNEL = "voice-reminders"
        private const val NOTIFICATION_ID = 319
    }
}

class RecommendationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("recommendation") ?: return
        val recommendations = Recommendations(context)
        when (intent.action) {
            Recommendations.REMIND -> recommendations.deliver(id)
            Recommendations.LATER -> recommendations.postpone(id)
            Recommendations.CONSULTED, Recommendations.SKIP -> recommendations.close(id)
        }
    }
}
