package org.findmyfam.services

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.findmyfam.models.AppSettings
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages app lock with biometric authentication.
 * Mirrors iOS AppLockService.
 */
@Singleton
class AppLockService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val settings: AppSettings
) {
    private val _isLocked = MutableStateFlow(false)
    val isLocked: StateFlow<Boolean> = _isLocked.asStateFlow()

    private val _isAuthenticating = MutableStateFlow(false)
    val isAuthenticating: StateFlow<Boolean> = _isAuthenticating.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private var hasUnlockedThisSession = false

    /**
     * Check if biometric authentication is available on this device.
     */
    fun isBiometricAvailable(): Boolean {
        val biometricManager = BiometricManager.from(context)
        return biometricManager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL
        ) == BiometricManager.BIOMETRIC_SUCCESS
    }

    /**
     * Called on app launch to determine initial lock state.
     */
    fun onLaunch() {
        if (settings.isAppLockEnabled) {
            _isLocked.value = true
        } else {
            _isLocked.value = false
            hasUnlockedThisSession = true
        }
    }

    /**
     * Called when app returns to foreground.
     */
    fun onResume() {
        if (!settings.isAppLockEnabled) {
            _isLocked.value = false
            return
        }
        if (hasUnlockedThisSession && !settings.isAppLockReauthOnForeground) {
            _isLocked.value = false
            return
        }
        _isLocked.value = true
    }

    /**
     * Attempt biometric unlock. Must be called from a FragmentActivity.
     */
    fun unlock(activity: FragmentActivity) {
        if (!settings.isAppLockEnabled) {
            _isLocked.value = false
            return
        }
        if (_isAuthenticating.value) return

        _isAuthenticating.value = true
        _errorMessage.value = null

        val executor = ContextCompat.getMainExecutor(activity)
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                hasUnlockedThisSession = true
                _isLocked.value = false
                _isAuthenticating.value = false
                _errorMessage.value = null
                Timber.i("App unlocked via biometric")
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                _isAuthenticating.value = false
                when (errorCode) {
                    BiometricPrompt.ERROR_USER_CANCELED,
                    BiometricPrompt.ERROR_NEGATIVE_BUTTON,
                    BiometricPrompt.ERROR_CANCELED -> {
                        // User cancelled — stay locked, no error message
                        _errorMessage.value = null
                    }
                    else -> {
                        _errorMessage.value = errString.toString()
                    }
                }
                Timber.w("Biometric auth error: $errString (code=$errorCode)")
            }

            override fun onAuthenticationFailed() {
                // Single attempt failed but prompt stays open — no action needed
                Timber.d("Biometric auth attempt failed")
            }
        }

        val prompt = BiometricPrompt(activity, executor, callback)
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock Famstr")
            .setSubtitle("Use biometrics or device credentials")
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
            .build()

        prompt.authenticate(promptInfo)
    }
}
