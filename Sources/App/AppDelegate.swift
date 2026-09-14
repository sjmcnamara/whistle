import UIKit
import WhistleCore

/// Minimal `AppDelegate` whose only job is observing *why* the process was
/// launched.
///
/// SwiftUI's App/Scene lifecycle needs no `AppDelegate` for normal operation
/// — `WhistleApp`'s own `.task` on the root view already runs
/// `AppViewModel.performFullStartup()` on every launch, headless or not,
/// because SwiftUI instantiates the `WindowGroup`'s view tree regardless of
/// launch reason. That path is what actually reconnects relays and resumes
/// location sharing after a background/reboot relaunch — this file adds
/// nothing to it.
///
/// What SwiftUI's lifecycle can't give us is *visibility* into why a launch
/// happened. Whistle relies on CoreLocation's documented behaviour of
/// relaunching an app in the background when a significant-location-change
/// event fires — including after a device reboot, since `LocationService`
/// registers for that monitoring (`allowsBackgroundLocationUpdates` +
/// `startMonitoringSignificantLocationChanges()`) — but until now nothing in
/// this codebase ever checked for that, so it was an unverified assumption
/// rather than a provable fact. This makes it provable: `launchOptions`
/// carrying the `.location` key is the OS's own signal that this is exactly
/// that kind of relaunch.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if Self.isLocationRelaunch(launchOptions) {
            WhistleLogger.location.notice(
                "App launched by CoreLocation (background/reboot recovery) — launchOptions carried .location"
            )
        }
        return true
    }

    /// Extracted so the detection logic is unit-testable without a real
    /// `UIApplication` launch.
    static func isLocationRelaunch(_ launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        launchOptions?[.location] != nil
    }
}
