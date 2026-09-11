package org.findmyfam.services

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
import androidx.core.content.ContextCompat
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.findmyfam.MainActivity
import org.findmyfam.R
import timber.log.Timber
import javax.inject.Inject

/**
 * Thin foreground-service shell. Its only real job is calling
 * startForeground(), which is what tells the OS to treat this process as
 * foreground-priority instead of an ordinary backgrounded app -- fixes the
 * "app halts within minutes of closing" report (no foreground Service
 * existed at all before this, despite FOREGROUND_SERVICE being declared in
 * the manifest as a dead permission).
 *
 * It does not own business logic: RelayService/MarmotService/LocationService
 * are Application-scoped Hilt singletons already shared with AppViewModel,
 * so once the *process* survives, whatever they were already doing survives
 * with it -- nothing here needs to re-drive them in the common case. It
 * still calls [BackgroundSessionCoordinator.ensureStarted] on every start,
 * because that call is a no-op once already running but is essential the
 * first time anything runs in this process at all -- headless launch from
 * the boot receiver, or an OS-triggered restart (START_STICKY) after the
 * whole process was killed despite foreground status.
 *
 * Declared and started as FOREGROUND_SERVICE_TYPE_DATA_SYNC, not location,
 * despite what this exists for -- confirmed live on a real reboot cycle:
 * Android throws SecurityException the instant a location/camera/
 * microphone-typed FGS calls startForeground() from a background context (a
 * BroadcastReceiver, here), even inside BOOT_COMPLETED's own temporary
 * background-start allowlist. This Service never calls a location API
 * itself -- LocationService does that, as a plain singleton with no FGS type
 * of its own -- so dataSync (syncing relay/MLS/location state) describes its
 * actual job just as accurately without hitting that restriction.
 */
@AndroidEntryPoint
class WhistleForegroundService : Service() {

    @Inject lateinit var coordinator: BackgroundSessionCoordinator

    private val scope = CoroutineScope(Dispatchers.IO + Job())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startForegroundCompat()
        } catch (e: Exception) {
            // Most likely a permission race (location permission revoked
            // between the caller's check and this call landing) -- nothing
            // useful this Service can do without it.
            Timber.e(e, "WhistleForegroundService: startForeground failed, stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        scope.launch {
            try {
                coordinator.ensureStarted()
            } catch (e: Exception) {
                Timber.e(e, "WhistleForegroundService: ensureStarted failed")
            }
            // A headless start (boot receiver, START_STICKY restart) can't
            // know in advance whether there's actually anything to share --
            // e.g. an install that has never been opened has zero groups.
            // Rather than leave a misleading persistent notification up for
            // an account with nothing to send, self-stop once ensureStarted
            // has had a chance to load groups and this can be checked for real.
            if (!coordinator.shouldBeSharing()) {
                Timber.i("WhistleForegroundService: nothing to share -- stopping")
                stopSelf()
            }
        }

        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Whistle")
            .setContentText("Sharing your location with your group")
            .setSmallIcon(R.drawable.ic_notification_location)
            .setOngoing(true)
            // Lowest priority: this notification exists only because Android
            // requires one for a foreground service, not to alert anyone of
            // anything -- silent, no sound/vibration, minimally intrusive.
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setContentIntent(openApp)
            .build()
    }

    companion object {
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "whistle_background_sharing"

        fun createNotificationChannel(context: Context) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Background location sharing",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "Shown while Whistle shares your location with your group in the background."
            }
            manager.createNotificationChannel(channel)
        }

        fun start(context: Context) {
            val intent = Intent(context, WhistleForegroundService::class.java)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, WhistleForegroundService::class.java))
        }
    }
}
