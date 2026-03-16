import Foundation
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

    // MARK: - Dependencies

    private let locationCache: LocationCache
    private let intervalSeconds: () -> Int   // closure so it's always current
    private var cancellable: AnyCancellable?

    // MARK: - Init

    /// - Parameters:
    ///   - locationCache: The shared location cache written by MarmotService.
    ///   - intervalSeconds: Closure returning the current location interval for stale detection.
    init(locationCache: LocationCache, intervalSeconds: @escaping () -> Int) {
        self.locationCache = locationCache
        self.intervalSeconds = intervalSeconds

        // Re-compute annotations whenever the cache changes
        cancellable = locationCache.$locations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    // MARK: - Refresh

    /// Re-derive annotations from the cache.
    func refresh() {
        let interval = intervalSeconds()
        annotations = locationCache.allLocations.map { loc in
            MemberAnnotation(
                id: loc.id,
                coordinate: loc.coordinate,
                displayName: loc.displayName,
                isStale: loc.isStale(intervalSeconds: interval),
                timestamp: loc.payload.date
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
