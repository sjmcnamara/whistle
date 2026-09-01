package org.findmyfam.services

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import androidx.core.app.NotificationCompat
import dagger.hilt.android.qualifiers.ApplicationContext
import org.findmyfam.R
import timber.log.Timber
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BatteryAlertService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val nicknameStore: NicknameStore,
    private val identity: IdentityService
) {
    companion object {
        const val CHANNEL_ID = "battery_alerts"
        const val THRESHOLD = 20

        fun createNotificationChannel(context: Context) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Low Battery Alerts",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Notifies when a group member's battery is low"
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private val lastKnownBattery = ConcurrentHashMap<String, Int>()
    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    /**
     * Delivery seam. Overridable in tests to observe *whether* an alert fires
     * without the notification stack — mirrors iOS's `deliver` closure so the
     * crossing/dedup logic is testable identically on both platforms.
     */
    var deliver: (name: String, battery: Int, pubkeyHex: String) -> Unit = ::postNotification

    fun check(pubkeyHex: String, battery: Int?) {
        battery ?: return
        val myPubkey = identity.publicKeyHex ?: return
        if (pubkeyHex == myPubkey) return

        val previous = lastKnownBattery[pubkeyHex]
        lastKnownBattery[pubkeyHex] = battery

        if (battery >= THRESHOLD) return
        if (previous != null && previous < THRESHOLD) return

        val name = nicknameStore.displayName(pubkeyHex)
        deliver(name, battery, pubkeyHex)
    }

    private fun postNotification(name: String, battery: Int, pubkeyHex: String) {
        Timber.i("Low battery alert: $name at $battery%")

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification_battery)
            .setContentTitle("Low Battery")
            .setContentText("$name's battery is at $battery%")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .build()

        notificationManager.notify("battery_$pubkeyHex".hashCode(), notification)
    }
}
