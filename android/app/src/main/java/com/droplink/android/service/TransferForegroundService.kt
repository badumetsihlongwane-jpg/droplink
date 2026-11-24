package com.droplink.android.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.droplink.android.MainActivity
import com.droplink.android.R
import com.droplink.android.protocol.FileUtils
import com.droplink.android.protocol.TransferStatus
import com.droplink.android.state.ConnectionState
import com.droplink.android.state.DropLinkManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

class TransferForegroundService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        val initialNotif = buildNotification("DropLink", "Encrypted local transfer active", null, null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, initialNotif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, initialNotif)
        }

        val manager = DropLinkManager.getInstance(applicationContext)
        serviceScope.launch {
            manager.uiState.collectLatest { state ->
                val active = state.transfers.filter {
                    it.status == TransferStatus.PENDING ||
                        it.status == TransferStatus.TRANSFERRING ||
                        it.status == TransferStatus.VERIFYING
                }

                when (val conn = state.connectionState) {
                    is ConnectionState.Connected -> {
                        if (active.isNotEmpty()) {
                            val totalBytes = active.sumOf { it.totalBytes }.coerceAtLeast(1L)
                            val doneBytes = active.sumOf { it.transferredBytes }
                            val pct = ((doneBytes * 100L) / totalBytes).toInt().coerceIn(0, 100)
                            val speed = active.sumOf { it.bytesPerSecond }
                            val title = if (active.size == 1) {
                                active[0].filename
                            } else {
                                "Transferring ${active.size} files"
                            }
                            val text = "$pct% • ${FileUtils.formatSpeed(speed)} • ${conn.macName}"
                            notifyUpdate(buildNotification(title, text, 100, pct))
                        } else {
                            notifyUpdate(buildNotification("Connected to ${conn.macName}", "Ready for encrypted Wi-Fi transfers", null, null))
                        }
                    }
                    is ConnectionState.Reconnecting -> {
                        notifyUpdate(buildNotification("Reconnecting…", "Attempt ${conn.attempt} to reach Mac", null, null))
                    }
                    is ConnectionState.Connecting -> {
                        notifyUpdate(buildNotification("Connecting…", "Establishing encrypted session", null, null))
                    }
                    else -> {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    }
                }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun ensureChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "DropLink Transfers",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows active local Wi-Fi connection and file transfer progress"
        }
        nm.createNotificationChannel(channel)
    }

    private fun notifyUpdate(notification: Notification) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, notification)
    }

    private fun buildNotification(title: String, content: String, maxProgress: Int?, progress: Int?): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_droplink_notif)
            .setContentTitle(title)
            .setContentText(content)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openIntent)

        if (maxProgress != null && progress != null) {
            builder.setProgress(maxProgress, progress, false)
        }
        return builder.build()
    }

    companion object {
        private const val CHANNEL_ID = "droplink_transfers"
        private const val NOTIFICATION_ID = 4201
        private const val ACTION_STOP = "com.droplink.android.STOP_SERVICE"

        fun start(context: Context) {
            val intent = Intent(context, TransferForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, TransferForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            runCatching { context.startService(intent) }
        }
    }
}
