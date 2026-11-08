package com.mrajkishor.phoneclone

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that keeps the process (and so the transfer) alive while
 * the app is in the background, with a progress notification. It also holds
 * a CPU wake lock and a Wi-Fi lock so the phone doesn't throttle the transfer
 * when the screen turns off.
 */
class TransferService : Service() {
    companion object {
        private const val CHANNEL_ID = "transfer"
        private const val NOTIFICATION_ID = 4711
        private var sending = true

        fun start(ctx: Context, title: String, text: String, isSending: Boolean) {
            sending = isSending
            val intent = Intent(ctx, TransferService::class.java)
                .putExtra("title", title).putExtra("text", text)
            ContextCompat.startForegroundService(ctx, intent)
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, TransferService::class.java))
        }

        @SuppressLint("MissingPermission")
        fun update(ctx: Context, title: String, text: String, progress: Int) {
            if (!running) return
            try {
                NotificationManagerCompat.from(ctx).notify(NOTIFICATION_ID, build(ctx, title, text, progress))
            } catch (_: SecurityException) {
                // notifications not allowed: the service still runs
            }
        }

        @Volatile
        private var running = false

        private fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = ctx.getSystemService(NotificationManager::class.java)
                if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                    nm.createNotificationChannel(
                        NotificationChannel(CHANNEL_ID, "Transfer progress", NotificationManager.IMPORTANCE_LOW)
                    )
                }
            }
        }

        private fun build(ctx: Context, title: String, text: String, progress: Int) =
            NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(if (sending) android.R.drawable.stat_sys_upload else android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setContentText(text)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setSilent(true)
                .setContentIntent(
                    PendingIntent.getActivity(
                        ctx, 0,
                        Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                    )
                )
                .apply {
                    if (progress in 0..100) setProgress(100, progress, false)
                    else setProgress(0, 0, true)
                }
                .build()
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel(this)
        val notification = build(
            this,
            intent?.getStringExtra("title") ?: "PhoneHop",
            intent?.getStringExtra("text") ?: "",
            -1
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        running = true
        acquireLocks()
        // If Android kills the process anyway, don't restart an empty service:
        // the next run resumes from the new phone's index instead.
        return START_NOT_STICKY
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PhoneTransfer:transfer")
                .apply { setReferenceCounted(false); acquire(12 * 60 * 60 * 1000L) }
        }
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wm.createWifiLock(mode, "PhoneTransfer:wifi").apply { setReferenceCounted(false); acquire() }
        }
    }

    override fun onDestroy() {
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock = null
        super.onDestroy()
    }
}
