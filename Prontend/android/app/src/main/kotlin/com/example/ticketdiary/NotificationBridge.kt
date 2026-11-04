package com.example.ticketdiary

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine

/** FCM foreground messages use the same channel as OS-delivered background messages. */
class NotificationBridge(private val activity: MainActivity, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "ticketdiary/notifications")
    /** 누른 알림의 data(JSON). null이면 누른 적 없음, ""면 data 없는 알림 */
    private var pendingTap: String? = null
    init {
        createChannel()
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "show" -> {
                        show(call.argument<String>("id") ?: System.nanoTime().toString(),
                            call.argument<String>("title") ?: "Ticket Diary",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("data") ?: "")
                        result.success(null)
                    }
                    "enabled" -> result.success(enabled())
                    "consumeTap" -> { result.success(pendingTap); pendingTap = null }
                    "settings" -> {
                        val intent = if (Build.VERSION.SDK_INT >= 26)
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                        else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.parse("package:${activity.packageName}"))
                        activity.startActivity(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("NOTIFICATION_ERROR", e.message, null) }
        }
    }
    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "공연·티켓 알림", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "공연 일정, 예매 및 티켓 배송 소식"
            })
        }
    }
    private fun enabled(): Boolean {
        if (!NotificationManagerCompat.from(activity).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }
    private fun show(id: String, title: String, body: String, data: String) {
        if (!enabled()) return
        val intent = Intent(activity, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(TAP, true)
            .putExtra(DATA, data)
        val pending = PendingIntent.getActivity(activity, id.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(activity, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title).setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true).setContentIntent(pending).build()
        NotificationManagerCompat.from(activity).notify(id.hashCode(), notification)
    }
    fun handleIntent(intent: Intent, notifyFlutter: Boolean) {
        if (!intent.getBooleanExtra(TAP, false)) return
        intent.removeExtra(TAP)
        pendingTap = intent.getStringExtra(DATA) ?: ""
        intent.removeExtra(DATA)
        if (notifyFlutter) channel.invokeMethod("tap", null)
    }
    companion object {
        const val CHANNEL_ID = "ticket_diary_updates"
        private const val TAP = "ticket_diary_notification_tap"
        private const val DATA = "ticket_diary_notification_data"
    }
}
