import Foundation
import WhistleCore
import CoreLocation
import MapKit
import Combine

/// Annotation model for map display — one per visible member pin.
struct MemberAnnotation: Identifiable {
    let id: String                        // same as MemberLocation.id
    let coordinate: CLLocationCoordinate2D
    let displayName: String
    let isStale: Bool
    let timestamp: Date
    /// `true` for the local user's own pin.
    let isMe: Bool
    /// Estimated time of next location broadcast — only set for the own pin.
    let nextUpdateDate: Date?
}

/// Transforms `LocationCache` entries into `[MemberAnnotation]` for the map.
///
/// Observes the cache and re-computes annotations whenever the cache changes.
/// Also provides a camera region that fits all visible pins.
@MainActor
final class LocationViewModel: ObservableObject {

    // MARK: - Published state

    /// Annotations ready for MapKit `Annotation` views.
    @Published private(set) var annotations: [MemberAnnotation] = []

    /// Region that fits all current annotations (or a default).
    @Published var region: MKCoordinateRegion = LocationViewModel.defaultRegion

    /// Filter to a specific group (nil = show all groups).
    @Published var selectedGroupId: String? {
        didSet { refresh() }
    }

    // MARK: - Dependencies

    private let locationCache: LocationCache
    private let nicknameStore: NicknameStore?
    private let intervalSeconds: () -> Int   // closure so it's always current
    private let myPubkeyHex: () -> String?
    private let nextFireDate: () -> Date?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    /// - Parameters:
    ///   - locationCache: The shared location cache written by MarmotService.
    ///   - nicknameStore: Optional nickname store for display name resolution.
    ///   - intervalSeconds: Closure returning the current location interval for stale detection.
    ///   - myPubkeyHex: Closure returning the local user's public key hex (for own-pin detection).
    ///   - nextFireDate: Closure returning the estimated next location broadcast time (own pin only).
    init(
        locationCache: LocationCache,
        nicknameStore: NicknameStore? = nil,
        intervalSeconds: @escaping () -> Int,
        myPubkeyHex: @escaping () -> String? = { nil },
        nextFireDate: @escaping () -> Date? = { nil }
    ) {
        self.locationCache = locationCache
        self.nicknameStore = nicknameStore
        self.intervalSeconds = intervalSeconds
        self.myPubkeyHex = myPubkeyHex
        self.nextFireDate = nextFireDate

        // Re-compute annotations whenever the cache changes
        locationCache.$locations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        // Re-compute annotations when nicknames change
        if let store = nicknameStore {
            store.$nicknames
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.refresh()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Refresh

    /// Re-derive annotations from the cache, applying the group filter.
    func refresh() {
        let interval = intervalSeconds()
        let source: [MemberLocation]
        if let groupId = selectedGroupId {
            source = locationCache.locations(forGroup: groupId)
        } else {
            source = locationCache.allLocations
        }

        let selfKey = myPubkeyHex()
        let nextUpdate = nextFireDate()
        annotations = source.map { loc in
            let name = nicknameStore?.displayName(for: loc.memberPubkeyHex) ?? loc.displayName
            let isMe = selfKey != nil && loc.memberPubkeyHex == selfKey
            return MemberAnnotation(
                id: loc.id,
                coordinate: loc.coordinate,
                displayName: name,
                isStale: loc.isStale(intervalSeconds: interval),
                timestamp: loc.payload.date,
                isMe: isMe,
                nextUpdateDate: isMe ? nextUpdate : nil
            )
        }

        if !annotations.isEmpty {
            region = Self.fittingRegion(for: annotations)
        }
    }

    // MARK: - Region helpers

    /// Default region centred on the US when no pins exist.
    static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.8283, longitude: -98.5795),
        span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
    )

    /// Compute a region that fits all annotations with some padding.
    static func fittingRegion(for annotations: [MemberAnnotation]) -> MKCoordinateRegion {
        guard !annotations.isEmpty else { return defaultRegion }

        var minLat = annotations[0].coordinate.latitude
        var maxLat = minLat
        var minLon = annotations[0].coordinate.longitude
        var maxLon = minLon

        for ann in annotations {
            minLat = min(minLat, ann.coordinate.latitude)
            maxLat = max(maxLat, ann.coordinate.latitude)
            minLon = min(minLon, ann.coordinate.longitude)
            maxLon = max(maxLon, ann.coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Add 20% padding around the span, with a minimum span
        let latDelta = max((maxLat - minLat) * 1.2, 0.01)
        let lonDelta = max((maxLon - minLon) * 1.2, 0.01)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
}
