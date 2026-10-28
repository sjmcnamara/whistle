package org.findmyfam.di

import android.content.Context
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import dev.ipf.marmotkit.Marmot
import dev.ipf.marmotkit.MarmotInterface
import dev.ipf.marmotkit.MarmotOptions
import dev.ipf.marmotkit.RelayPolicyFfi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.findmyfam.models.AppSettings
import org.findmyfam.services.ChatMessageCache
import org.findmyfam.services.LocationCache
import org.findmyfam.services.MarmotKitService
import org.findmyfam.services.MemberAvatarStore
import org.findmyfam.services.NicknameStore
import org.findmyfam.services.SharedGroupAvatarStore
import timber.log.Timber
import java.io.File
import javax.inject.Singleton

/**
 * Hilt provisioning for MarmotKit.
 *
 * Everything else in the graph has an `@Inject` constructor and needs no
 * module. MarmotKit does, because its runtime takes a root path and a relay
 * list at construction, and because there must be exactly one of it.
 */
@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    /**
     * The MarmotKit service. **One per process**, and that is not an
     * optimisation.
     *
     * A runtime owns its root directory exclusively for as long as its handle
     * lives, so a second instance on the same root fails with `RuntimeBusy`.
     * Android makes this easy to trip over: [org.findmyfam.services.WhistleForegroundService]
     * can start from a boot receiver before any Activity exists, and both it
     * and the UI reach MarmotKit through this graph. `@Singleton` in
     * `SingletonComponent` gives one instance for the process, which they
     * share.
     *
     * The runtime itself is built lazily by the factory below rather than
     * here, so identity replacement can drop it
     * ([MarmotKitService.releaseRuntime]), advance the root generation, and
     * have the next `start()` open a fresh root — without the singleton
     * itself having to be replaced, which Hilt could not do.
     */
    @Provides
    @Singleton
    fun provideMarmotKitService(
        @ApplicationContext context: Context,
        settings: AppSettings,
        locationCache: LocationCache,
        nicknameStore: NicknameStore,
        memberAvatarStore: MemberAvatarStore,
        sharedGroupAvatarStore: SharedGroupAvatarStore,
        chatMessageCache: ChatMessageCache,
    ): MarmotKitService = MarmotKitService(
        runtimeFactory = { buildRuntime(context, settings) },
        relayUrls = dialledRelays(context, settings),
        // Wired here, not in AppViewModel: WhistleForegroundService can start
        // the service headlessly from a boot receiver with no ViewModel at
        // all, and with these null every inbound location, nickname and avatar
        // is dropped silently (each use is `?.`).
        locationCache = locationCache,
        nicknameStore = nicknameStore,
        memberAvatarStore = memberAvatarStore,
        sharedGroupAvatarStore = sharedGroupAvatarStore,
        chatMessageCache = chatMessageCache,
        // Not a `viewModelScope`: the foreground service outlives every
        // ViewModel, and cancelling the receive loop when the UI goes away
        // would stop background location sharing.
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    )

    private fun buildRuntime(context: Context, settings: AppSettings): MarmotInterface {
        // Read live, not captured: after `advanceMarmotKitRootGeneration()`
        // the next runtime must land on the new generation's directory.
        val root = MarmotKitService.rootPath(context.filesDir, settings.marmotKitRootGeneration)
        val relays = dialledRelays(context, settings)
        Timber.i("Opening MarmotKit at $root with ${relays.size} relay(s)")
        return Marmot.newWithConfiguration(
            rootPath = root,
            relayUrls = relays,
            options = MarmotOptions(
                relayPolicy = RelayPolicyFfi.PUBLIC_ONLY,
                // Null means the platform keyring — Android Keystore. It works
                // in the app; only JVM unit tests cannot reach it, and those
                // mock the whole interface rather than injecting a store.
                secretStore = null,
            ),
        )
    }

    /**
     * The user's enabled relays, filtered to what MarmotKit will dial.
     *
     * Filtered *before* the runtime is constructed, deliberately: a
     * relay-list declaration naming a retired host fails the entire relay
     * directory fetch with "relay endpoint host is retired", which on iOS
     * presented as a total startup failure rather than one bad URL. Falls back
     * to the unfiltered list rather than an empty one — "no relays configured"
     * would be a worse lie than "one of these may not work".
     */
    private fun dialledRelays(context: Context, settings: AppSettings): List<String> {
        val configured = settings.relays.filter { it.isEnabled }.map { it.url }
        if (configured.isEmpty()) return emptyList()
        val probeRoot = File(context.cacheDir, "marmotkit-relay-policy")
        val usable = MarmotKitService.allowedRelayEndpoints(probeRoot, configured)
        if (usable.size != configured.size) {
            Timber.w("Skipping unusable relay(s): ${configured - usable.toSet()}")
        }
        return usable.ifEmpty { configured }
    }
}
