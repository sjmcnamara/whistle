import SwiftUI
import LocalAuthentication
import Security

@main
struct FindMyFamApp: App {

    @StateObject private var appViewModel = AppViewModel()
    @StateObject private var appLockService = AppLockService(settings: AppSettings.shared)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(appViewModel)

                if appViewModel.startupPhase != .ready {
                    SplashView(phase: appViewModel.startupPhase)
                        .transition(.opacity)
                        .zIndex(1)
                }

                if appLockService.isLocked {
                    AppLockView(
                        isAuthenticating: appLockService.isAuthenticating,
                        errorMessage: appLockService.errorMessage,
                        onUnlock: {
                            Task { await appLockService.unlock() }
                        },
                        onUsePasscode: {
                            Task { await appLockService.unlockWithPasscode() }
                        }
                    )
                    .transition(.opacity)
                    .zIndex(2)
                }
            }
            .animation(.easeOut(duration: 0.45), value: appViewModel.startupPhase == .ready)
            .task {
                appLockService.onLaunch()
                await appViewModel.onAppear()
                await appLockService.onBecameActive()
            }
            .onChange(of: scenePhase) { _, newPhase in
                appLockService.refreshFromSettings()
                switch newPhase {
                case .active:
                    Task { await appLockService.onBecameActive() }
                case .inactive, .background:
                    appLockService.onWillResignActive()
                @unknown default:
                    break
                }
            }
            .onOpenURL { url in
                appViewModel.handleIncomingURL(url)
            }
        }
    }
}

@MainActor
final class AppLockService: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?

    private let settings: AppSettings
    private var hasUnlockedThisSession = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func onLaunch() {
        guard settings.isAppLockEnabled else {
            isLocked = false
            hasUnlockedThisSession = true
            errorMessage = nil
            return
        }
        isLocked = true
    }

    func refreshFromSettings() {
        if settings.isAppLockEnabled {
            if !hasUnlockedThisSession {
                isLocked = true
            }
        } else {
            isLocked = false
            hasUnlockedThisSession = true
            errorMessage = nil
        }
    }

    func onBecameActive() async {
        guard settings.isAppLockEnabled else { return }
        guard !isAuthenticating else { return }

        if hasUnlockedThisSession && !settings.isAppLockReauthOnForeground {
            isLocked = false
            return
        }

        if isLocked {
            await unlock()
        }
    }

    func onWillResignActive() {
        guard settings.isAppLockEnabled else { return }
        guard !isAuthenticating else { return }
        if settings.isAppLockReauthOnForeground {
            isLocked = true
        }
    }

    /// Biometric-first unlock flow.
    func unlock() async {
        guard settings.isAppLockEnabled else {
            isLocked = false
            return
        }
        guard !isAuthenticating else { return }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let success = try await attempt(policy: .deviceOwnerAuthenticationWithBiometrics)
            applyUnlockResult(success)
        } catch let error as LAError {
            switch error.code {
            case .userFallback, .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled, .authenticationFailed:
                await unlockWithPasscodeInternal()
            case .userCancel, .systemCancel, .appCancel:
                isLocked = true
                errorMessage = nil
            default:
                isLocked = true
                errorMessage = error.localizedDescription
            }
        } catch {
            isLocked = true
            errorMessage = (error as NSError).localizedDescription
        }
    }

    /// Explicit passcode flow for users who cannot use biometrics right now.
    func unlockWithPasscode() async {
        guard settings.isAppLockEnabled else {
            isLocked = false
            return
        }
        guard !isAuthenticating else { return }

        isAuthenticating = true
        defer { isAuthenticating = false }

        await unlockWithPasscodeInternal()
    }

    private func unlockWithPasscodeInternal() async {
        do {
            let success = try await attemptPasscodeOnly()
            applyUnlockResult(success)
        } catch let error as LAError {
            isLocked = true
            switch error.code {
            case .userCancel, .systemCancel, .appCancel:
                errorMessage = nil
            default:
                errorMessage = error.localizedDescription
            }
        } catch {
            isLocked = true
            errorMessage = (error as NSError).localizedDescription
        }
    }

    private func applyUnlockResult(_ success: Bool) {
        if success {
            hasUnlockedThisSession = true
            isLocked = false
            errorMessage = nil
        } else {
            isLocked = true
            errorMessage = "Authentication was not completed."
        }
    }

    private func attempt(policy: LAPolicy) async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Passcode"

        var authError: NSError?
        let canEvaluate = context.canEvaluatePolicy(policy, error: &authError)
        guard canEvaluate else {
            throw authError ?? NSError(domain: LAError.errorDomain, code: LAError.biometryNotAvailable.rawValue)
        }

        return try await evaluate(context: context, policy: policy)
    }

    private func attemptPasscodeOnly() async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .devicePasscode,
            &accessError
        ) else {
            if let error = accessError?.takeRetainedValue() {
                throw error
            }
            throw NSError(domain: LAError.errorDomain, code: LAError.passcodeNotSet.rawValue)
        }

        return try await withCheckedThrowingContinuation { continuation in
            context.evaluateAccessControl(access, operation: .useItem, localizedReason: "Unlock FindMyFam") { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: success)
            }
        }
    }

    private func evaluate(context: LAContext, policy: LAPolicy) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: "Unlock FindMyFam") { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: success)
            }
        }
    }
}

struct AppLockView: View {
    let isAuthenticating: Bool
    let errorMessage: String?
    let onUnlock: () -> Void
    let onUsePasscode: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("FindMyFam Locked")
                    .font(.title3.weight(.semibold))

                Text("Use Face ID, Touch ID, or device passcode to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: 10) {
                    Button {
                        onUnlock()
                    } label: {
                        if isAuthenticating {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Unlocking...")
                            }
                        } else {
                            Label("Unlock with Face ID", systemImage: "faceid")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAuthenticating)

                    Button("Use Passcode") {
                        onUsePasscode()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAuthenticating)
                }
            }
            .padding(24)
        }
    }
}
