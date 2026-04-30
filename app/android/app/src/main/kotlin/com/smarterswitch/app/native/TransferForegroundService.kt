package com.smarterswitch.app.native

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.smarterswitch.app.MainActivity
import com.smarterswitch.app.R

/**
 * Foreground service that holds the Android process alive while a transfer
 * is in progress. Without this, the OS aggressively kills the app's
 * networking and CPU once the user backgrounds the app or the screen
 * sleeps — which is exactly what users do during a 30-minute photo
 * transfer.
 *
 * `foregroundServiceType="dataSync"` is the right choice here: we're
 * actively syncing the user's data between two of their own devices.
 * That type is exempt from the doze/idle policies that kill the
 * connection on Android 14+.
 *
 * The service does no transfer work itself — Dart-side code keeps doing
 * the streaming on the main isolate. The service exists purely to keep
 * the OS from reclaiming us.
 */
class TransferForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "smarterswitch_transfer"
        const val NOTIFICATION_ID = 27042
        const val ACTION_START = "com.smarterswitch.app.START_TRANSFER"
        const val ACTION_STOP = "com.smarterswitch.app.STOP_TRANSFER"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // STOP_FOREGROUND_REMOVE is API 24+; we target API 21+ but
            // the int constant is forwards-compatible.
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Transfer",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Ongoing transfer status"
                    setShowBadge(false)
                }
                nm.createNotificationChannel(channel)
            }
        }
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentPi =
            PendingIntent.getActivity(this, 0, openIntent, pendingFlags)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return builder
            .setContentTitle("SmarterSwitch — transferring")
            .setContentText("Keeping the connection alive in the background")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(contentPi)
            .build()
    }
}
