package org.findmyfam

import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.ViewModelProvider
import dagger.hilt.android.AndroidEntryPoint
import org.findmyfam.models.AppSettings
import org.findmyfam.services.AppLockService
import org.findmyfam.ui.common.AppLockScreen
import org.findmyfam.ui.common.RootScreen
import org.findmyfam.ui.theme.FindMyFamTheme
import org.findmyfam.viewmodels.AppViewModel
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : FragmentActivity() {

    @Inject lateinit var appLockService: AppLockService
    @Inject lateinit var appSettings: AppSettings

    // Same ViewModelStore as the AppViewModel Compose resolves via
    // hiltViewModel() in RootScreen -- launchMode="singleTask" means this
    // Activity instance (and its ViewModelStore) survives a tapped
    // whistle:// link, so handleIntent() below and RootScreen's collector
    // are always talking to the same instance.
    private val appViewModel: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handleIntent(intent)

        appLockService.onLaunch()

        setContent {
            val appearance by appSettings.appearanceFlow.collectAsState()
            FindMyFamTheme(appearance = appearance) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    val isLocked by appLockService.isLocked.collectAsState()
                    val isAuthenticating by appLockService.isAuthenticating.collectAsState()
                    val errorMessage by appLockService.errorMessage.collectAsState()

                    Box(modifier = Modifier.fillMaxSize()) {
                        RootScreen()

                        AnimatedVisibility(
                            visible = isLocked,
                            enter = fadeIn(),
                            exit = fadeOut()
                        ) {
                            AppLockScreen(
                                isAuthenticating = isAuthenticating,
                                errorMessage = errorMessage,
                                onUnlock = { appLockService.unlock(this@MainActivity) }
                            )
                        }
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        appLockService.onResume()
        // Auto-prompt if locked
        if (appLockService.isLocked.value && !appLockService.isAuthenticating.value) {
            appLockService.unlock(this)
        }
        // Restart relay subscriptions if backgrounding tore them down without
        // a proper resume -- see AppViewModel.onForeground for why.
        appViewModel.onForeground()
    }

    // Fires when a whistle:// link is tapped while this Activity's task is
    // already running -- singleTask launchMode routes it here instead of
    // spawning a second instance. onCreate above covers the cold-start case.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent) {
        val uri = intent.data ?: return
        appViewModel.handleIncomingUri(uri)
    }
}
