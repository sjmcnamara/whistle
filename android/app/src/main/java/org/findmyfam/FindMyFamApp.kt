package org.findmyfam

import android.app.Application
import dagger.hilt.android.HiltAndroidApp
import dev.ipf.marmotkit.MarmotAndroid
import org.findmyfam.services.BatteryAlertService
import org.findmyfam.services.LocalGroupAvatarStore
import org.findmyfam.services.WhistleForegroundService
import org.osmdroid.config.Configuration
import timber.log.Timber

@HiltAndroidApp
class FindMyFamApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Timber.plant(Timber.DebugTree())

        // Must run before the first `Marmot(...)` construction, anywhere.
        // MarmotKit's keyring store talks to the Android Keystore over JNI and
        // needs `ndk-context` initialised with the application Context first;
        // without this the constructor crashes with "android context was not
        // initialized". Upstream documents it on `MarmotAndroid.initialize`.
        MarmotAndroid.initialize(this)

        // Configure osmdroid tile cache
        Configuration.getInstance().apply {
            userAgentValue = packageName
            osmdroidTileCache = cacheDir.resolve("osmdroid")
        }

        LocalGroupAvatarStore.init(this)
        BatteryAlertService.createNotificationChannel(this)
        WhistleForegroundService.createNotificationChannel(this)

        Timber.i("FindMyFam application started")
    }
}
