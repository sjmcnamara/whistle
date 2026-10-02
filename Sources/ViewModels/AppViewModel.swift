import Foundation
import UIKit
import WhistleCore
import CoreLocation
import NostrSDK
import Combine

/// Root view-model. Owns the core services and coordinates startup.
@MainActor
final class AppViewModel: ObservableObject {

    let identity: IdentityService
    let settings: AppSettings

    /// User-facing warnings and errors, rendered once at the root rather than
    /// per screen — see `NoticeCenter`.
    let notices = NoticeCenter()

    /// Mirrors `MarmotKitService.accountIsReady`.
    ///
    /// Exists because `forwardChildChanges()` does not forward `marmot` — and
    /// must not, since every relay event would then re-render every observing
    /// view. That left `appViewModel.marmot?.accountIsReady` compiling, type
    /// checking and passing every test while never updating on screen, which
    /// is a mistake this migration made three times.
    ///
    /// Mirroring it here makes the obvious thing correct: a view reads
    /// `appViewModel.accountIsReady` and gets updates, the same as
    /// `settings`. The subscription that maintains it already existed for the
    /// setup banner.
    @Published private(set) var accountIsReady = false

    /// Marmot orchestration layer — bridges MLS ↔ Relay (v0.3).
    @Published private(set) var marmot: MarmotKitService?

    // MARK: - Location (v0.4)

    /// CoreLocation wrapper — publishes via callback.
    let locationService: LocationService
    let motionService: MotionService

    /// Shared in-memory cache of group members' latest locations.
    let locationCache: LocationCache

    /// View-model for the map — observes `locationCache`.
    let locationViewModel: LocationViewModel

    // MARK: - Chat & Nicknames (v0.5)

    /// Local nickname store — maps pubkey hex → display name.
    let nicknameStore: NicknameStore
    let memberAvatarStore: MemberAvatarStore
    let sharedGroupAvatarStore: SharedGroupAvatarStore

    /// In-memory cache of loaded chat threads so re-entering a chat renders
    /// instantly instead of flashing empty while MDK reloads.
    let chatMessageCache: ChatMessageCache

    // MARK: - Pending Invites (v0.6)

    /// GroupListViewModel — owned here so it survives SwiftUI view identity
    /// changes. Created once after MarmotKitService is ready.
    @Published private(set) var groupListViewModel: GroupListViewModel?

    /// Current user's public key hex — convenience for ViewModels.
    var myPubkeyHex: String? { identity.identity?.publicKeyHex }

    // MARK: - Startup / Splash (v0.7.1)

    enum StartupPhase: Equatable {
        case connecting
        case initialisingEncryption
        case loadingGroups
        case ready

        var message: String {
            switch self {
            case .connecting:              return "Connecting to relays…"
            case .initialisingEncryption:  return "Setting up encryption…"
            case .loadingGroups:           return "Loading groups…"
            case .ready:                   return ""
            }
        }
    }

    @Published private(set) var startupPhase: StartupPhase = .connecting

    /// Mirrors `identity.identityAnomalyDetected` — surfaced here so
    /// `WhistleApp`'s top-level view can react without observing
    /// `IdentityService` directly. See that property's doc comment.
    @Published private(set) var identityAnomalyDetected = false

    /// MLS initialisation error surfaced to the UI (non-fatal — app works without it).
    @Published private(set) var mlsError: String?

    /// Drives the map's "Whistle" button feedback (manual force-publish).
    @Published private(set) var whistleState: WhistleState = .idle

    /// Set while a manual whistle is in flight so the next `broadcastLocation`
    /// is recognised as the forced send and flips `whistleState` to `.sent`.
    private var pendingWhistle = false

    enum WhistleState: Equatable {
        case idle, sending, sent, failed
    }

    /// Tracks whether onAppear has completed — prevents duplicate startup.
    private var didStart = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.identity        = IdentityService()
        self.settings        = AppSettings.shared
        self.locationService = LocationService()
        self.motionService   = MotionService()
        UIDevice.current.isBatteryMonitoringEnabled = true
        self.locationCache   = LocationCache()
        self.nicknameStore       = NicknameStore()
        self.memberAvatarStore   = MemberAvatarStore()
        self.sharedGroupAvatarStore = SharedGroupAvatarStore()
        self.chatMessageCache    = ChatMessageCache()

        let cache = self.locationCache
        let settingsRef = self.settings
        let nicknames = self.nicknameStore
        let identityRef = self.identity
        let locationSvc = self.locationService
        let motionSvc = self.motionService
        self.locationViewModel = LocationViewModel(
            locationCache: cache,
            nicknameStore: nicknames,
            intervalSeconds: { settingsRef.locationIntervalSeconds },
            myPubkeyHex: { identityRef.identity?.publicKeyHex },
            nextFireDate: {
                guard let last = locationSvc.lastFireDate else { return nil }
                let effective = TimeInterval(settingsRef.locationIntervalSeconds) * locationSvc.motionMultiplier
                let computed = last.addingTimeInterval(effective)
                // Clamp to "now" so SwiftUI's Text(date, style: .relative) never
                // flips into count-up mode while we're waiting for the next GPS
                // fix to arrive after the throttle has already expired.
                return max(computed, Date())
            },
            isStationary: { motionSvc.isStationary && settingsRef.isMotionAdaptiveEnabled }
        )

        // Forward objectWillChange from nested ObservableObjects so that
        // SwiftUI views observing AppViewModel re-render when child
        // @Published properties change (e.g. SettingsView watching
        // locationService.authorizationStatus, settings.isLocationPaused,
        // relay.connectionState).
        forwardChildChanges()

        // Observe settings changes immediately — NOT in onAppear() which
        // runs async and may not reach the subscription code in time.
        observeSettings()
    }

    /// Forward `objectWillChange` from nested ObservableObjects so views
    /// that observe AppViewModel (via @EnvironmentObject) re-render when
    /// child properties change. Merged and debounced to avoid cascading
    /// render cycles when multiple children publish in quick succession.
    private func forwardChildChanges() {
        // `marmot` is deliberately absent: forwarding every
        // `MarmotKitService` change here would re-render every observing view
        // on each relay event. Views that need its state observe a published
        // property on a view model, or hold it in `@State` fed by a `.task`.
        Publishers.Merge(
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            locationService.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Subscribe to settings changes. Called from init() so the observers
    /// are active before any async startup work.
    private func observeSettings() {
        settings.$isLocationPaused
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLocationPauseSetting()
            }
            .store(in: &cancellables)

        settings.$locationIntervalSeconds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newInterval in
                guard let self else { return }
                self.locationService.intervalSeconds = newInterval
                self.locationService.resetThrottle()
                WhistleLogger.location.info("Interval changed to \(newInterval)s, throttle reset")
            }
            .store(in: &cancellables)

        // When the fuzz setting changes, reset the throttle so the very next
        // CoreLocation update broadcasts the corrected (or restored accurate)
        // position immediately rather than waiting out the remaining interval.
        settings.$locationFuzzMeters
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.locationService.resetThrottle()
                WhistleLogger.location.info("Fuzz setting changed, throttle reset for immediate rebroadcast")
            }
            .store(in: &cancellables)

        // When motion-adaptive setting changes, reapply the current motion state.
        settings.$isMotionAdaptiveEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.applyMotionMultiplier(isStationary: self.motionService.isStationary, enabled: enabled)
            }
            .store(in: &cancellables)

        // When the device transitions between stationary and moving, scale the interval
        // and refresh the map so the stationary badge updates immediately.
        motionService.$isStationary
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isStationary in
                guard let self else { return }
                self.applyMotionMultiplier(isStationary: isStationary, enabled: self.settings.isMotionAdaptiveEnabled)
                self.locationViewModel.refresh()
            }
            .store(in: &cancellables)

        // When location authorization changes (user taps "Enable Location"
        // in Settings), re-apply the pause setting so updates actually start.
        locationService.$authorizationStatus
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let isAuthorized = status == .authorizedWhenInUse || status == .authorizedAlways
                if isAuthorized {
                    WhistleLogger.location.info("Location authorization granted — re-applying pause setting")
                    self.applyLocationPauseSetting()
                }
            }
            .store(in: &cancellables)

        // Seed own display name into NicknameStore, and broadcast to
        // all groups whenever it changes.
        settings.$displayName
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] newName in
                guard let self else { return }
                if let pubkey = self.myPubkeyHex {
                    self.nicknameStore.set(name: newName, for: pubkey)
                }
                Task { @MainActor [weak self] in
                    await self?.broadcastNicknameToAllGroups()
                }
            }
            .store(in: &cancellables)

        // Seed initial value (no broadcast — we do that after Marmot starts)
        if let pubkey = myPubkeyHex, !settings.displayName.isEmpty {
            nicknameStore.set(name: settings.displayName, for: pubkey)
        }
    }

    // MARK: - Deep Link Handling
    //
    // Both v1 deep links are gone, and neither has a v2 replacement.
    // `whistle://invite` carried an invite code a non-member acted on, and
    // protocol v2 has no out-of-group messaging for them to act *with*;
    // `whistle://addmember` carried a group id the prospect could only have
    // learned from such an invite. Adding a member is now always admin-side
    // and in-group (`ScanMemberCodeView`), so there is nothing to route.

    private func errorMessage(for error: Error) -> String {
        let desc = error.localizedDescription
        // Translate common MarmotError cases into plain English.
        if desc.contains("noKeyPackageFound") || desc.contains("key package") {
            return "Could not find this person's key package on the relay. Ask them to re-open the app and share the invite again."
        }
        return desc
    }

    /// Called once when the app becomes active.
    func onAppear() async {
        guard !didStart else { return }
        didStart = true

        // Yield to the main run loop once so SwiftUI can commit the first
        // SplashView frame before we start heavy async work.  Without this,
        // on cold launch the .task fires before the first frame is drawn and
        // the splash never reaches the screen.
        await Task.yield()

        // First launch: skip all Rust init and show onboarding immediately.
        // The full startup runs after onboarding completes via onOnboardingComplete().
        if !settings.hasCompletedOnboarding {
            startupPhase = .ready
            return
        }

        await performFullStartup()
    }

    /// Called when the onboarding carousel finishes. Kicks off the full
    /// startup sequence (identity, relay, MLS) with the splash visible.
    func onOnboardingComplete() async {
        didStart = false
        startupPhase = .connecting
        await performFullStartup()
    }

    /// User tapped "Try Again" on the identity-anomaly screen — re-attempts
    /// startup from scratch. Won't help within the same process unless
    /// something external changed (e.g. this build's entitlements now
    /// include a previously-dropped Keychain access group and the identity
    /// becomes reachable), but costs nothing to offer.
    func retryAfterIdentityAnomaly() async {
        identityAnomalyDetected = false
        didStart = false
        startupPhase = .connecting
        await performFullStartup()
    }

    /// User explicitly confirmed "Create New Identity Anyway" on the
    /// identity-anomaly screen. Never called automatically.
    func confirmNewIdentityDespiteAnomaly() async {
        await identity.createNewIdentityDespiteAnomaly()
        identityAnomalyDetected = false
        didStart = false
        startupPhase = .connecting
        await performFullStartup()
    }

    private func performFullStartup() async {
        // Load the Nostr identity. Runs Rust FFI (Keys.generate/parse) and
        // Secure Enclave crypto on a background thread — slow on first launch
        // and would freeze the splash if called on the main thread.
        //
        // `IdentityService` still owns the key on disk under v2. MarmotKit has
        // its own keyring, but the identity has to come from somewhere on an
        // upgrade, and this is where existing users' keys already are.
        await identity.initialise()

        // Record the time so we can enforce a minimum splash display duration.
        let splashStart = ContinuousClock.now

        if identity.identityAnomalyDetected {
            // Existing local group data but no reachable identity — do NOT
            // treat this as "first launch, show onboarding." Surface the
            // anomaly screen instead and stop; WhistleApp blocks on
            // `identityAnomalyDetected` until the user explicitly resolves it
            // (relaunch after fixing access, or the explicit override).
            identityAnomalyDetected = true
            startupPhase = .ready
            return
        }

        guard let nsec = identity.exportNsec() else {
            WhistleLogger.relay.error("No identity available — cannot start MarmotKit")
            didStart = false
            startupPhase = .ready   // dismiss splash so onboarding/empty state is visible
            return
        }

        // Relays are MarmotKit's to connect, not ours — there is no separate
        // RelayService step under v2. Retired endpoints are filtered out
        // first: a relay-list declaration naming one fails the whole directory
        // fetch with "relay endpoint host is retired", which on device looked
        // like a total startup failure rather than one bad URL.
        let configured = settings.relays.filter(\.isEnabled).map(\.url)
        let usable = MarmotKitService.allowedRelayEndpoints(from: configured)
        if usable.count != configured.count {
            let dropped = Set(configured).subtracting(usable).sorted().joined(separator: ", ")
            WhistleLogger.marmot.warning("Skipping retired relay(s): \(dropped)")
        }

        startupPhase = .initialisingEncryption

        let service: MarmotKitService
        do {
            service = try MarmotKitService(
                rootPath: try MarmotKitService.defaultRootPath(),
                relayUrls: usable.isEmpty
                    ? MarmotKitService.allowedRelayEndpoints(from: AppDefaults.defaultRelays)
                    : usable
            )
        } catch {
            let msg = error.localizedDescription
            WhistleLogger.marmot.error("MarmotKit init failed: \(msg)")
            mlsError = msg
            startupPhase = .ready
            return
        }
        service.locationCache = locationCache
        service.nicknameStore = nicknameStore
        service.memberAvatarStore = memberAvatarStore
        service.sharedGroupAvatarStore = sharedGroupAvatarStore
        service.batteryAlertService = BatteryAlertService(
            myPubkeyHex: identity.identity?.publicKeyHex ?? "",
            nicknameStore: nicknameStore
        )
        BatteryAlertService.requestPermission()

        do {
            // Adopts the key the app already holds, so the npub carries over.
            // Idempotent — signs back into the existing account on every
            // launch after the first.
            _ = try await service.start(
                adoptingNsec: nsec,
                expecting: identity.identity?.publicKeyHex
            )
        } catch {
            let msg = error.localizedDescription
            WhistleLogger.marmot.error("MarmotKit start failed: \(msg)")
            mlsError = msg
            // Previously only visible in Advanced Settings' MLS row, so a
            // failed start looked like an app that simply had no groups.
            notices.post(NoticeCenter.Banner(
                cause: .startupFailed,
                message: "Whistle couldn't start securely: \(msg)",
                actionTitle: "Retry",
                action: { [weak self] in
                    self?.didStart = false
                    await self?.onAppear()
                }
            ))
            startupPhase = .ready
            return
        }

        // Let the main run loop drain so the UI stays responsive.
        await Task.yield()

        // Load persisted groups from MarmotKit's database BEFORE publishing
        // the service to the UI — this avoids a flash of empty state and
        // ensures GroupListViewModel sees groups immediately.
        startupPhase = .loadingGroups
        await service.refreshGroups()
        WhistleLogger.marmot.info("Loaded \(service.groups.count) group(s) from MarmotKit")

        await Task.yield()

        // Create GroupListViewModel (owned by AppViewModel so it survives
        // SwiftUI view identity changes in RootView's conditional branches).
        self.groupListViewModel = GroupListViewModel(
            marmot: service,
            displayName: { [weak self] in self?.settings.displayName ?? "" }
        )

        // Now publish to UI — GroupListView will receive a fully loaded service.
        self.marmot = service

        // Enforce a minimum splash display time so the animation has time to
        // play even when startup is very fast.
        let minimumSplash: Duration = .seconds(1.0)
        let elapsed = ContinuousClock.now - splashStart
        if elapsed < minimumSplash {
            try? await Task.sleep(for: minimumSplash - elapsed)
        }

        startupPhase = .ready

        // --- Everything below runs after the splash dismisses. ---
        // The UI is now interactive; these are background housekeeping tasks.

        // Re-announce the group photo, and our own nickname/avatar, when
        // membership changes, so a new joiner picks up existing members'
        // profiles without waiting for each of them to next launch or edit.
        // The group photo is guarded to the designated admin inside (a shared
        // value, so only one sender should push it); the nickname/avatar
        // re-announce has no such guard — every existing member's device
        // independently resends only its own profile, so there's no
        // duplicate-sender problem to avoid.
        service.$lastGroupMembershipChangeId
            .compactMap { $0?.0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groupId in
                Task { [weak self] in
                    await self?.rebroadcastGroupAvatarIfDesignated(groupId: groupId)
                    await self?.reannounceOwnProfile(toGroup: groupId)
                }
            }
            .store(in: &cancellables)

        // Auto-broadcast display name when we are added to a group.
        service.$lastJoinedGroupId
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak service] groupId in
                guard let self, let service else { return }
                let name = self.settings.displayName
                guard !name.isEmpty else { return }
                Task {
                    try? await service.sendNicknameUpdate(name: name, toGroup: groupId)
                    WhistleLogger.chat.info("Auto-broadcast nickname to newly joined group \(groupId)")
                    // Avatar goes to the new group only — unlike the nickname it is
                    // never re-announced on launch, so joining is the one chance the
                    // new group has to learn our face without waiting for a change.
                    if let pubkey = self.myPubkeyHex,
                       let payload = self.memberAvatarStore.ownPayload(pubkeyHex: pubkey) {
                        try? await service.sendAvatarUpdate(payload, toGroup: groupId)
                        WhistleLogger.chat.info("Auto-broadcast avatar to newly joined group \(groupId)")
                    }
                }
            }
            .store(in: &cancellables)

        // The receive loop's failures finally have somewhere to go.
        // `lastError` was published and had no consumer at all, so anything it
        // reported was dropped on the floor.
        service.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.notices.postToast(message)
            }
            .store(in: &cancellables)

        // Account setup is a *state*, so it gets a banner rather than a toast:
        // until it completes, groups cannot be created and nobody can invite
        // this device, and a toast would vanish while that stayed true.
        service.$accountIsReady
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak service] ready in
                guard let self else { return }
                self.accountIsReady = ready
                self.notices.setBanner(
                    .accountSetupIncomplete,
                    active: !ready,
                    message: NoticeCenter.Banner(
                        cause: .accountSetupIncomplete,
                        message: "Still publishing your account. You can't create or join groups until this finishes.",
                        actionTitle: "Retry",
                        action: { [weak service] in
                            _ = try? await service?.completeAccountSetup()
                        }
                    )
                )
            }
            .store(in: &cancellables)

        // A relay the user has enabled but MarmotKit refuses to dial is a
        // standing misconfiguration, not a transient failure — it needs
        // correcting in Settings, so it gets a banner. The per-row policy
        // label in Advanced Settings only helps someone already looking at
        // that screen.
        service.$relayStatus
            .map { status -> [String] in
                status.policies.filter { $0.value != "allowed" }.keys.sorted()
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unusable in
                guard let self else { return }
                self.notices.setBanner(
                    .relayUnusable,
                    active: !unusable.isEmpty,
                    message: NoticeCenter.Banner(
                        cause: .relayUnusable,
                        message: unusable.count == 1
                            ? "\(unusable[0]) can't be used. Remove it in Settings → Advanced."
                            : "\(unusable.count) relays can't be used. Check Settings → Advanced."
                    )
                )
            }
            .store(in: &cancellables)

        // Wire location pipeline: LocationService → MarmotKitService (all groups)
        wireLocationPipeline(marmot: service)

        // Start or stop location based on current pause setting
        applyLocationPauseSetting()

        // Start the receive loop. Returns immediately — the subscription runs
        // inside MarmotKit's runtime.
        service.startSubscriptions()

        // Deferred work — runs after UI is interactive so startup feels snappy.
        await broadcastNicknameToAllGroups()

        // Finish account setup. `beginOnboarding` stops at local-ready by
        // design, so until this runs the account has no published relay list
        // or KeyPackage and anything needing one fails with
        // `OnboardingRequired` — which is what "my member code" hit.
        //
        // Deliberately here rather than on the launch path: this is the half
        // that waits on relays, and `MemberCodeView` already gates the code
        // on `setupReadiness()` reaching `.networkReady`, so showing the
        // screen early degrades to "Publishing your key…" instead of handing
        // out a code no admin can invite.
        do {
            WhistleLogger.marmot.info("Relays handed to MarmotKit: \(usable.joined(separator: ", "))")
            let readiness = try await service.completeAccountSetup()
            WhistleLogger.marmot.info("Account setup readiness: \(String(describing: readiness))")
        } catch {
            // Non-fatal — retried on next launch, and the readiness gate
            // stops a half-published account being shown as scannable.
            WhistleLogger.marmot.warning("Account setup did not complete: \(error)")
        }

        // Always dumped, success or failure. The first version logged this
        // only on the success path, so the run that actually needed it — the
        // one where setup threw — printed nothing and the counters that
        // distinguish "relays never connected" from "relays connected but the
        // list would not publish" were missing.
        let relayState = await service.relayDiagnostics()
        WhistleLogger.marmot.info("\(relayState)")
        for line in (try? service.onboardingDiagnostics()) ?? [] {
            WhistleLogger.marmot.info("onboarding \(line)")
        }
    }

    // MARK: - Location Pipeline

    /// Wire `LocationService.onLocationUpdate` to broadcast location via MarmotKitService.
    private func wireLocationPipeline(marmot: MarmotKitService) {
        locationService.intervalSeconds = settings.locationIntervalSeconds

        locationService.onLocationUpdate = { [weak self, weak marmot] location in
            guard let self, let marmot else { return }
            Task { @MainActor in
                await self.broadcastLocation(location, via: marmot)
            }
        }
        WhistleLogger.location.info("Location pipeline wired (interval=\(self.settings.locationIntervalSeconds)s)")
    }

    /// Force an immediate location publish, ignoring the throttle, motion
    /// backoff, and pause state. Drives the map's "Whistle" button.
    func whistle() {
        guard whistleState != .sending else { return }
        whistleState = .sending
        pendingWhistle = true
        locationService.requestImmediateUpdate()

        // Resolve the button state even if no fix arrives (denied, no signal,
        // no active groups). The forced send flips this to `.sent` first if it
        // lands; otherwise we report failure.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard self.pendingWhistle else { return }
            self.pendingWhistle = false
            self.whistleState = .failed
            self.scheduleWhistleReset()
        }
    }

    /// Return the button to its resting state a short moment after a terminal
    /// (sent/failed) result so the confirmation is visible but transient.
    private func scheduleWhistleReset() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if self.whistleState == .sent || self.whistleState == .failed {
                self.whistleState = .idle
            }
        }
    }

    /// Send a location update to every active MLS group.
    ///
    /// Also inserts the user's own location into `LocationCache` so it appears
    /// on the map immediately — relays may not echo back our own events.
    private func broadcastLocation(_ location: CLLocation, via marmot: MarmotKitService) async {
        let activeGroups = marmot.groups.filter(\.isActive)
        guard !activeGroups.isEmpty else {
            WhistleLogger.location.warning("broadcastLocation: no active groups — \(marmot.groups.count) total group(s)")
            return
        }

        let fuzzRadius = settings.locationFuzzMeters
        let lat: Double
        let lon: Double
        if fuzzRadius > 0 {
            let fuzzed = fuzzedCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                radiusMeters: Double(fuzzRadius)
            )
            lat = fuzzed.lat
            lon = fuzzed.lon
            WhistleLogger.location.debug("Location fuzzed by up to \(fuzzRadius)m")
        } else {
            lat = location.coordinate.latitude
            lon = location.coordinate.longitude
        }

        let batteryLevel = UIDevice.current.batteryLevel
        let battery: Int? = batteryLevel >= 0 ? Int(batteryLevel * 100) : nil

        let payload = LocationPayload(
            latitude: lat,
            longitude: lon,
            altitude: location.altitude,
            accuracy: fuzzRadius > 0 ? max(location.horizontalAccuracy, Double(fuzzRadius)) : location.horizontalAccuracy,
            timestamp: Date(), // broadcast time, not acquisition time — avoids stale-pin false positives with imprecise location
            battery: battery,
            interval: locationService.effectiveIntervalSeconds, // reflects motion multiplier so receivers grade staleness against real cadence
            // Only meaningful while Movement Aware is on; otherwise send nil
            // ("unknown") rather than false, which would claim we're moving.
            stationary: settings.isMotionAdaptiveEnabled ? motionService.isStationary : nil
        )

        // Insert our own location into the cache immediately so the map
        // shows our pin without waiting for a relay round-trip.
        if let myKey = myPubkeyHex {
            for group in activeGroups {
                locationCache.update(
                    groupId: group.mlsGroupId,
                    memberPubkeyHex: myKey,
                    payload: payload
                )
            }
        }

        for group in activeGroups where !settings.pausedGroupIds.contains(group.mlsGroupId) {
            do {
                try await marmot.sendLocation(payload, toGroup: group.mlsGroupId)
                WhistleLogger.location.info("Location sent to group \(group.mlsGroupId)")
            } catch {
                WhistleLogger.location.error("Failed to send location to group \(group.mlsGroupId): \(error)")
            }
        }

        // A manual whistle resolves to "sent" as soon as its forced fix is
        // broadcast (the timeout in `whistle()` only fires if none arrives).
        if pendingWhistle {
            pendingWhistle = false
            whistleState = .sent
            scheduleWhistleReset()
        }
    }

    /// Start or stop location updates based on the current pause setting.
    ///
    /// Note: does NOT call `requestAuthorization()` — that's triggered by the
    /// "Enable Location" button in Settings to avoid iOS silently dropping
    /// the permission prompt during early app lifecycle.
    ///
    /// Guards against starting location updates before `wireLocationPipeline()`
    /// has set the `onLocationUpdate` callback. The CLLocationManager delegate
    /// fires via Task after LocationService.init(), which can trigger this
    /// method (via Combine observer) before `onAppear()` wires the pipeline.
    /// Stopping is always allowed so the user can pause sharing immediately.
    private func applyLocationPauseSetting() {
        if settings.isLocationPaused {
            locationService.stopUpdating()
            motionService.stopMonitoring()
        } else if locationService.onLocationUpdate != nil {
            locationService.startUpdating()
            if settings.isMotionAdaptiveEnabled {
                motionService.startMonitoring()
            }
        }
        // If pipeline not yet wired, onAppear() will call this again after wireLocationPipeline().
    }

    private func applyMotionMultiplier(isStationary: Bool, enabled: Bool) {
        let multiplier = (enabled && isStationary) ? MotionService.stationaryMultiplier : 1.0
        locationService.motionMultiplier = multiplier
        WhistleLogger.location.info(
            "Motion-adaptive: \(enabled ? "on" : "off"), stationary=\(isStationary), multiplier=\(multiplier)×"
        )
    }

    // MARK: - Identity Replacement (v0.8.2)

    /// Replace the current Nostr identity, tearing down all key-bound state
    /// and restarting the app from scratch with the new key.
    ///
    /// Called from ImportKeyView after user confirms the destructive action.
    func replaceIdentity(withNsec nsec: String) async throws {
        // 1. Stop location updates
        locationService.stopUpdating()

        // 3. Tear down Marmot and GroupList.
        //
        // The account is removed through MarmotKit *before* the handle is
        // dropped. v1 wiped its own database here and that was the whole job;
        // MarmotKit keeps a separate store with its own signing key, so
        // skipping this left the old identity on the device — and because
        // startup matches an account by id, the next launch would have signed
        // straight back into it and carried on as the previous user.
        accountIsReady = false
        await marmot?.forgetCurrentAccount()
        await marmot?.shutdown()
        marmot = nil
        groupListViewModel = nil

        // The next service gets a fresh root. `shutdown()` does not release
        // the runtime's claim on the old one — the handle does, when it is
        // dropped — and a still-presented view holding this service is enough
        // to keep it alive past this point. Reusing the root would then fail
        // with `RuntimeBusy`, telling the user their import failed when the
        // key was fine. The superseded directory is deleted on next launch.
        MarmotKitService.advanceIdentityGeneration()

        // 4. Remove all Combine pipelines and timers (will be re-wired below)
        // No key-rotation timer to tear down — MarmotKit rotates its own
        // keys, so the app no longer schedules it.
        cancellables.removeAll()

        // 5. Clear all identity-bound stores
        nicknameStore.clearAll()
        LocalGroupAvatarStore.shared.removeAll()
        // Member avatars are photographs of real people — they must not survive
        // an identity burn any more than the groups they came from do.
        memberAvatarStore.removeAll()
        sharedGroupAvatarStore.removeAll()
        locationCache.clear()
        chatMessageCache.clear()

        // 6. Reset identity-bound settings
        settings.lastEventTimestamp = 0
        settings.processedEventIds = []
        settings.pendingGiftWrapEventIds = []

        // 7. Clear residual UserDefaults data — chat/read timestamps used by
        //    GroupListViewModel, and any Keychain fallback data.
        UserDefaults.standard.removeObject(forKey: "groupLastReadTimestamps")
        UserDefaults.standard.removeObject(forKey: "groupLastChatTimestamps")
        UserDefaults.standard.removeObject(forKey: "fmf.keychain.fallback.org.findmyfam.nsec")
        UserDefaults.standard.removeObject(forKey: "fmf.pendingWelcomes")

        // v1's MLS database is not wiped here any more: it is no longer
        // written to, and MarmotKit's own store is dealt with above by
        // `forgetCurrentAccount()` plus the generation bump. A pre-v2 install
        // upgrading still has `whistle.db` on disk; removing it is a separate
        // cleanup, not part of identity replacement.

        // 9. Destroy old key from Keychain before importing new one.
        //    This ensures the old nsec is explicitly deleted, not just overwritten.
        identity.destroyCurrentKey()

        // 10. Import the new key
        try identity.importKey(nsec: nsec)

        // 11. Seed display name for new identity
        if let pubkey = myPubkeyHex, !settings.displayName.isEmpty {
            nicknameStore.set(name: settings.displayName, for: pubkey)
        }

        // 12. Re-wire Combine pipelines and restart.
        forwardChildChanges()
        observeSettings()
        didStart = false
        startupPhase = .connecting
        await onAppear()
    }

    // MARK: - Burn Identity planning

    /// Compute what burning will do to every active group, before showing
    /// any confirmation. A group where we're the sole admin can't just be
    /// left — MDK's leaveGroup already refuses that — so those need an
    /// explicit decision: promote another member, or accept that group
    /// ends when we burn.
    func prepareBurnPlan() async -> BurnPlan {
        guard let marmot, let myPubkey = myPubkeyHex else {
            return BurnPlan(leaving: [], promoteOrEnd: [], ending: [])
        }
        var leaving: [BurnPlan.LeavingGroup] = []
        var promoteOrEnd: [BurnPlan.PromoteOrEndGroup] = []
        var ending: [BurnPlan.EndingGroup] = []
        for group in marmot.groups where group.isActive {
            let groupId = group.mlsGroupId
            // Read live group state rather than the cached row: whether this
            // group can simply be left turns on the admin list, and deciding
            // it from stale data would strand a group with no admin.
            let freshGroup = try? await marmot.group(id: groupId)
            let adminPubkeys = freshGroup?.adminPubkeys ?? group.adminPubkeys
            let amSoleAdmin = adminPubkeys.contains(myPubkey) && adminPubkeys.count == 1
            let name = freshGroup?.displayName ?? group.displayName
            guard amSoleAdmin else {
                leaving.append(BurnPlan.LeavingGroup(groupId: groupId, groupName: name))
                continue
            }
            let members = (try? await marmot.members(ofGroup: groupId)) ?? []
            let candidates = members
                .filter { $0 != myPubkey }
                .map { BurnPlan.Candidate(pubkeyHex: $0, displayName: nicknameStore.displayName(for: $0)) }
                .sorted { $0.displayName < $1.displayName }
            if candidates.isEmpty {
                ending.append(BurnPlan.EndingGroup(groupId: groupId, groupName: name))
            } else {
                promoteOrEnd.append(BurnPlan.PromoteOrEndGroup(groupId: groupId, groupName: name, candidates: candidates))
            }
        }
        return BurnPlan(leaving: leaving, promoteOrEnd: promoteOrEnd, ending: ending)
    }

    /// Execute a reviewed burn plan: promote where chosen, leave everything
    /// leavable, then burn. Never blocks on an individual group's failure —
    /// a compromised key being burned is a worse problem than one frozen or
    /// stranded group, so we log and continue rather than abort.
    func executeBurnPlan(_ plan: BurnPlan, promotions: [String: String]) async {
        var groupNames: [String: String] = [:]
        for g in plan.leaving { groupNames[g.groupId] = g.groupName }
        for g in plan.promoteOrEnd { groupNames[g.groupId] = g.groupName }

        WhistleLogger.chat.info(
            "Burn plan starting: \(plan.leaving.count) leaving, \(plan.promoteOrEnd.count) promote-or-end, \(plan.ending.count) ending"
        )

        var toLeave = plan.leaving.map(\.groupId)
        for group in plan.promoteOrEnd {
            guard let promoteePubkey = promotions[group.groupId] else {
                WhistleLogger.chat.info("Burn plan: \(group.groupName) (\(group.groupId)) — no promotee chosen, group will end")
                continue
            }
            do {
                try await marmot?.promoteToAdmin(promoteePubkey, inGroup: group.groupId)
                WhistleLogger.chat.info("Burn plan: promoted \(promoteePubkey) in \(group.groupName) (\(group.groupId))")
                toLeave.append(group.groupId)
            } catch {
                WhistleLogger.chat.error("Burn plan: promote FAILED for \(group.groupName) (\(group.groupId)): \(error) — group will end")
            }
        }
        for groupId in toLeave {
            let name = groupNames[groupId] ?? groupId
            do {
                try await marmot?.leaveGroup(groupId)
                WhistleLogger.chat.info("Burn plan: left \(name) (\(groupId)) successfully")
            } catch {
                WhistleLogger.chat.error("Burn plan: leave FAILED for \(name) (\(groupId)): \(error)")
            }
        }
        WhistleLogger.chat.info("Burn plan complete, proceeding to destroy identity")
        try? await burnIdentity()
    }

    // MARK: - Burn Identity

    /// Destroy the current identity and all associated state, then generate
    /// a fresh keypair and restart. This is a one-way operation.
    ///
    /// Called directly only when there's nothing to review (no active
    /// groups) — normal callers should go through `prepareBurnPlan()` /
    /// `executeBurnPlan(_:promotions:)` above so groups are left first.
    func burnIdentity() async throws {
        // Generate a new key first so we have the nsec ready
        let freshKeys = Keys.generate()
        let freshNsec = try freshKeys.secretKey().toBech32()

        // Clear the display name — this is a brand-new identity
        settings.displayName = ""

        // Reuse the full teardown + restart pipeline
        try await replaceIdentity(withNsec: freshNsec)
    }

    // MARK: - Relay Reconnect

    /// Disconnect and reconnect to relays using the current settings.
    /// Called when the user toggles, adds, or removes relays.
    /// Apply a relay-list change as far as v2 allows.
    ///
    /// This used to disconnect and reconnect v1's `RelayService`, which the v2
    /// path never connects — so editing relays did nothing at all. What *can*
    /// be done live is republish the account's declared list, so others
    /// discover us on the new relay. What cannot: change which relays this
    /// runtime dials. `relayUrls` is init-only, and publishing a new list
    /// provably leaves the dialled pool unchanged
    /// (`MarmotKitRuntimeRelaySetTests`), so that part needs a relaunch and
    /// the UI says so rather than showing a count that omits the new relay.
    func reconnectRelays() async {
        guard let marmot else { return }
        let enabled = settings.relays.filter(\.isEnabled).map(\.url)
        do {
            try await marmot.publishRelayLists(defaultRelays: enabled)
            WhistleLogger.marmot.info("Published relay list: \(enabled.joined(separator: ", "))")
        } catch {
            WhistleLogger.marmot.warning("Could not publish relay list: \(error)")
        }
        await marmot.refreshRelayStatus(
            all: settings.relays.map(\.url),
            enabled: enabled
        )
    }

    // MARK: - Nickname Broadcasting

    /// Send the user's display name to every active group so other members
    /// can resolve it. Called on startup and whenever the name changes.
    func broadcastNicknameToAllGroups() async {
        let name = settings.displayName
        guard !name.isEmpty, let marmot else { return }

        for group in marmot.groups where group.isActive {
            do {
                try await marmot.sendNicknameUpdate(name: name, toGroup: group.mlsGroupId)
            } catch {
                WhistleLogger.chat.error("Failed to broadcast nickname to group \(group.mlsGroupId): \(error)")
            }
        }
        WhistleLogger.chat.info("Broadcast nickname '\(name)' to \(marmot.groups.filter(\.isActive).count) group(s)")
    }

    // MARK: - Avatar

    /// Set the local user's avatar from picked image data and announce it to
    /// every active group. Returns false if the image could not be encoded
    /// within the wire size cap, so the UI can tell the user rather than
    /// leaving them with an avatar only they can see.
    @discardableResult
    func setOwnAvatar(data: Data) async -> Bool {
        guard let pubkey = myPubkeyHex else { return false }
        guard let payload = await memberAvatarStore.setOwnImage(data: data, pubkeyHex: pubkey) else {
            return false
        }
        await broadcastAvatar(payload)
        return true
    }

    /// Clear the local user's avatar and tell every active group to drop it.
    func removeOwnAvatar() async {
        guard let pubkey = myPubkeyHex else { return }
        await broadcastAvatar(memberAvatarStore.removeOwnImage(pubkeyHex: pubkey))
    }

    // MARK: - Group photo (admin-only)

    /// Outcome of setting a group photo, so the UI can say *why* it failed.
    ///
    /// Deliberately not a Bool: the first version returned one and was marked
    /// `@discardableResult`, so the call site dropped it and every failure —
    /// oversized image, missing admin rights — looked identical to success with
    /// no photo appearing. Callers must now handle the result.
    enum GroupAvatarUpdate: Equatable {
        case updated
        case notAdmin
        case couldNotEncode
    }

    /// Set the group's shared photo and announce it.
    func setGroupAvatar(data: Data, groupId: String) async -> GroupAvatarUpdate {
        guard let marmot, let pubkey = myPubkeyHex,
              await marmot.isAdmin(pubkey, ofGroup: groupId) else {
            WhistleLogger.chat.warning("Group avatar rejected locally: not an admin of \(groupId)")
            return .notAdmin
        }
        guard let payload = await sharedGroupAvatarStore.setImage(data: data, for: groupId) else {
            WhistleLogger.chat.error("Group avatar for \(groupId) could not be encoded within the size cap")
            return .couldNotEncode
        }
        do {
            try await marmot.sendGroupAvatarUpdate(payload, toGroup: groupId)
        } catch {
            WhistleLogger.chat.error("Failed to broadcast group avatar for \(groupId): \(error)")
        }
        return .updated
    }

    /// Clear the group's shared photo and tell the group to drop it.
    func removeGroupAvatar(groupId: String) async {
        guard let marmot, let pubkey = myPubkeyHex,
              await marmot.isAdmin(pubkey, ofGroup: groupId) else { return }
        let payload = sharedGroupAvatarStore.removeImagePayload(for: groupId)
        do {
            try await marmot.sendGroupAvatarUpdate(payload, toGroup: groupId)
        } catch {
            WhistleLogger.chat.error("Failed to broadcast group avatar removal for \(groupId): \(error)")
        }
    }

    /// Re-announce the group photo when membership changes, so a new joiner
    /// sees it without waiting for the next edit.
    ///
    /// Only the designated admin sends. Every admin observes the same membership
    /// change, so without this a three-admin group would push three copies of
    /// the image to every member.
    private func rebroadcastGroupAvatarIfDesignated(groupId: String) async {
        guard let marmot, let pubkey = myPubkeyHex,
              await marmot.designatedBroadcaster(forGroup: groupId) == pubkey,
              let payload = sharedGroupAvatarStore.payload(for: groupId) else { return }
        do {
            try await marmot.sendGroupAvatarUpdate(payload, toGroup: groupId)
            WhistleLogger.chat.info("Re-announced group avatar to \(groupId) after membership change")
        } catch {
            WhistleLogger.chat.error("Group avatar re-announce failed for \(groupId): \(error)")
        }
    }

    /// Re-announce our own nickname and avatar to one group after a
    /// membership change there, so a newly-joined member picks up existing
    /// members' profiles instead of only ever seeing their npub. Each device
    /// resends only its own profile — no coordination needed, unlike the
    /// group photo above.
    private func reannounceOwnProfile(toGroup groupId: String) async {
        guard let marmot, let pubkey = myPubkeyHex else { return }
        let name = settings.displayName
        if !name.isEmpty {
            do {
                try await marmot.sendNicknameUpdate(name: name, toGroup: groupId)
            } catch {
                WhistleLogger.chat.error("Nickname re-announce failed for \(groupId): \(error)")
            }
        }
        if let payload = memberAvatarStore.ownPayload(pubkeyHex: pubkey) {
            do {
                try await marmot.sendAvatarUpdate(payload, toGroup: groupId)
                WhistleLogger.chat.info("Re-announced own avatar to \(groupId) after membership change")
            } catch {
                WhistleLogger.chat.error("Avatar re-announce failed for \(groupId): \(error)")
            }
        }
    }

    /// Send an avatar payload to every active group.
    ///
    /// Unlike nicknames this is deliberately *not* re-broadcast on launch: a
    /// name is a few bytes, whereas an avatar is several KB per group per
    /// launch. Change, join, and another member's membership-change
    /// re-announce (see `reannounceOwnProfile`) are the only triggers.
    private func broadcastAvatar(_ payload: AvatarPayload) async {
        guard let marmot else { return }
        let active = marmot.groups.filter(\.isActive)
        for group in active {
            do {
                try await marmot.sendAvatarUpdate(payload, toGroup: group.mlsGroupId)
            } catch {
                WhistleLogger.chat.error("Failed to broadcast avatar to group \(group.mlsGroupId): \(error)")
            }
        }
        let action = payload.isRemoval ? "removal" : "update"
        WhistleLogger.chat.info("Broadcast avatar \(action) to \(active.count) group(s)")
    }
}
