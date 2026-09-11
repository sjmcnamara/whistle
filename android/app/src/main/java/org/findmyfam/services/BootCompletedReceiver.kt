package org.findmyfam.services

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager.PERMISSION_GRANTED
import androidx.core.content.ContextCompat
import timber.log.Timber

/**
 * Restarts location sharing after a reboot -- fixes the "does not run on
 * startup" half of the GrapheneOS background report. Before this, nothing
 * ran until the user manually reopened the app; a rebooted phone shared
 * nothing with its groups until someone happened to notice and launch it.
 *
 * The permission check here is a cheap early exit, not the real gate --
 * whether there's actually anything to share (any active group) can only be
 * known after [BackgroundSessionCoordinator] loads groups from MDK, so
 * [WhistleForegroundService] does that fuller check itself and self-stops if
 * there's nothing to do. This just avoids spinning up the whole relay/MLS
 * bootstrap for the case we can already rule out for free: no location
 * permission at all (revoked while the device was off, or never granted).
 * [IdentityService] always has a keypair once constructed, so an identity
 * check would never actually gate anything here.
 */
class BootCompletedReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val hasLocationPermission =
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PERMISSION_GRANTED
        if (!hasLocationPermission) {
            Timber.i("BootCompletedReceiver: no location permission -- nothing to restart")
            return
        }

        Timber.i("BootCompletedReceiver: restarting WhistleForegroundService after boot")
        WhistleForegroundService.start(context)
    }
}
