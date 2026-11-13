package com.scanora.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/** Keeps the process eligible to run a document job begun in the app. */
class DocumentProcessingService : Service() {
    companion object {
        private const val CHANNEL_ID = "scanora_document_processing"
        private const val NOTIFICATION_ID = 2081
        private val jobs = linkedMapOf<Int, Boolean>()
        private var service: DocumentProcessingService? = null

        // Called from the activity and service on the Android main thread.
        fun begin(context: Context, id: Int, persian: Boolean): Boolean {
            val first = jobs.isEmpty()
            jobs[id] = persian
            try {
                if (first) {
                    val intent = Intent(context, DocumentProcessingService::class.java)
                        .putExtra("persian", persian)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(intent)
                    } else {
                        context.startService(intent)
                    }
                } else {
                    service?.refresh()
                }
                return true
            } catch (_: RuntimeException) {
                jobs.remove(id)
                return false
            }
        }

        fun finish(id: Int) {
            jobs.remove(id)
            service?.refresh()
        }

        fun finishAll() {
            jobs.clear()
            service?.refresh()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        service = this
        val persian = jobs.values.lastOrNull() ?: intent?.getBooleanExtra("persian", false) ?: false
        try {
            startForeground(NOTIFICATION_ID, notification(persian))
        } catch (_: RuntimeException) {
            jobs.clear()
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (jobs.isEmpty()) stopSelf(startId)
        return START_NOT_STICKY
    }

    private fun refresh() {
        val persian = jobs.values.lastOrNull()
        if (persian == null) {
            stopSelf()
        } else {
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, notification(persian))
        }
    }

    private fun notification(persian: Boolean): Notification {
        val title = if (persian) "اسکنورا در حال پردازش فایل است" else "Scanora is processing a file"
        val text = if (persian) "برای بازگشت به برنامه، این اعلان را باز کنید." else "Open this notification to return to Scanora."
        val openApp = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pending = PendingIntent.getActivity(
            this, 0, openApp, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = if (persian) "پردازش فایل" else "File processing"
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW)
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder.setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pending)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        jobs.clear()
        stopSelf()
    }

    override fun onDestroy() {
        if (service === this) service = null
        super.onDestroy()
    }
}
