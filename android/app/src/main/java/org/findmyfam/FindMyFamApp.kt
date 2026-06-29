package org.findmyfam

import android.app.Application
import dagger.hilt.android.HiltAndroidApp
import org.findmyfam.services.BatteryAlertService
import org.findmyfam.services.LocalGroupAvatarStore
import org.osmdroid.config.Configuration
import timber.log.Timber

@HiltAndroidApp
class FindMyFamApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Timber.plant(Timber.DebugTree())

        // Configure osmdroid tile cache
        Configuration.getInstance().apply {
            userAgentValue = packageName
            osmdroidTileCache = cacheDir.resolve("osmdroid")
        }

        LocalGroupAvatarStore.init(this)
        BatteryAlertService.createNotificationChannel(this)

        Timber.i("FindMyFam application started")
    }
}
