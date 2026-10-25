package com.markschmidt.sift

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.markschmidt.sift.core.store.MessageRecord

/**
 * Alerts and the launcher badge. Both are off unless a sender opts in, and
 * permission is only requested the first time one does.
 *
 * Android launchers draw badges from notifications, so the badge is a silent,
 * low-priority notification whose number is the count of unread mail from
 * badged senders.
 */
class Notifier(private val context: Context) {
    companion object {
        const val MAIL_CHANNEL = "mail"
        const val BADGE_CHANNEL = "badge"
        const val EXTRA_THREAD = "threadId"
        private const val BADGE_ID = 1
    }

    private val manager = NotificationManagerCompat.from(context)

    fun createChannels() {
        val system = context.getSystemService(NotificationManager::class.java)
        system.createNotificationChannel(
            NotificationChannel(MAIL_CHANNEL, "Mail from senders you follow", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Only senders you've turned alerts on for, in their sender settings."
                setShowBadge(true)
            }
        )
        system.createNotificationChannel(
            NotificationChannel(BADGE_CHANNEL, "Unread count", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Keeps the app icon's badge in step with unread mail from badged senders. Silent."
                setShowBadge(true)
                setSound(null, null)
                enableVibration(false)
            }
        )
    }

    val canPost: Boolean
        get() = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun post(messages: List<MessageRecord>) {
        if (messages.isEmpty() || !canPost) return
        for (message in messages) {
            val notification = NotificationCompat.Builder(context, MAIL_CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(message.senderDisplayName)
                .setContentText(message.subject.ifEmpty { "(no subject)" })
                .setStyle(NotificationCompat.BigTextStyle().bigText("${message.subject}\n${message.preview}"))
                .setGroup(message.threadId)
                .setCategory(NotificationCompat.CATEGORY_EMAIL)
                .setAutoCancel(true)
                .setContentIntent(openThread(message.threadId))
                .build()
            runCatching { manager.notify(message.id.hashCode(), notification) }
        }
    }

    fun setBadge(count: Int) {
        if (count <= 0 || !canPost) {
            manager.cancel(BADGE_ID)
            return
        }
        val notification = NotificationCompat.Builder(context, BADGE_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("$count unread from badged senders")
            .setNumber(count)
            .setBadgeIconType(NotificationCompat.BADGE_ICON_SMALL)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(openThread(null))
            .build()
        runCatching { manager.notify(BADGE_ID, notification) }
    }

    private fun openThread(threadId: String?): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            threadId?.let { putExtra(EXTRA_THREAD, it) }
        }
        return PendingIntent.getActivity(
            context, threadId?.hashCode() ?: 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
