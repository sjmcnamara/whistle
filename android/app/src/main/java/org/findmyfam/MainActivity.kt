package org.findmyfam

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
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
import org.findmyfam.services.AppLockService
import org.findmyfam.ui.common.AppLockScreen
import org.findmyfam.ui.common.RootScreen
import org.findmyfam.ui.theme.FindMyFamTheme
import org.findmyfam.viewmodels.AppViewModel
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : FragmentActivity() {

    @Inject lateinit var appLockService: AppLockService

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        appLockService.onLaunch()

        setContent {
            FindMyFamTheme {
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
    }
}
