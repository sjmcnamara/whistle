import Foundation

/// Apply a random offset to a coordinate within `radiusMeters`.
/// Uses a uniform random bearing and distance for a circular (not Gaussian) distribution.
func fuzzedCoordinate(latitude: Double, longitude: Double, radiusMeters: Double) -> (lat: Double, lon: Double) {
    let bearing = Double.random(in: 0..<2 * .pi)
    let distance = Double.random(in: 0...radiusMeters)
    return offsetCoordinate(latitude: latitude, longitude: longitude, bearing: bearing, distance: distance)
}

/// Deterministic spherical-earth offset for a given bearing and distance in metres.
/// Separated from randomness so the geometry can be unit-tested independently.
func offsetCoordinate(latitude: Double, longitude: Double, bearing: Double, distance: Double) -> (lat: Double, lon: Double) {
    let earthRadius = 6_371_000.0
    let latRad = latitude * .pi / 180
    let lonRad = longitude * .pi / 180

    let newLatRad = asin(
        sin(latRad) * cos(distance / earthRadius) +
        cos(latRad) * sin(distance / earthRadius) * cos(bearing)
    )
    let newLonRad = lonRad + atan2(
        sin(bearing) * sin(distance / earthRadius) * cos(latRad),
        cos(distance / earthRadius) - sin(latRad) * sin(newLatRad)
    )
    return (newLatRad * 180 / .pi, newLonRad * 180 / .pi)
}

/// Haversine distance in metres between two lat/lon coordinates.
func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let earthRadius = 6_371_000.0
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
            sin(dLon / 2) * sin(dLon / 2)
    return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
}
