import XCTest
@testable import Whistle

/// Tests for the spherical-earth location fuzzing helpers in LocationFuzz.swift.
final class LocationFuzzTests: XCTestCase {

    // MARK: - offsetCoordinate (deterministic)

    func testNorthwardOffsetIncreasesLatitude() {
        // Due north (bearing = 0) should increase latitude, longitude unchanged
        let result = offsetCoordinate(latitude: 0, longitude: 0, bearing: 0, distance: 1000)
        XCTAssertGreaterThan(result.lat, 0)
        XCTAssertEqual(result.lon, 0, accuracy: 0.0001)
    }

    func testEastwardOffsetIncreasesLongitude() {
        // Due east (bearing = π/2) should increase longitude, latitude roughly unchanged
        let result = offsetCoordinate(latitude: 0, longitude: 0, bearing: .pi / 2, distance: 1000)
        XCTAssertGreaterThan(result.lon, 0)
        XCTAssertEqual(result.lat, 0, accuracy: 0.001)
    }

    func testZeroDistanceReturnsOrigin() {
        let result = offsetCoordinate(latitude: 51.5, longitude: -0.12, bearing: 1.23, distance: 0)
        XCTAssertEqual(result.lat, 51.5, accuracy: 1e-10)
        XCTAssertEqual(result.lon, -0.12, accuracy: 1e-10)
    }

    func testOffsetProducesExpectedDistance() {
        // 100 m north from London — result should be ~100 m away
        let origin = (lat: 51.5074, lon: -0.1278)
        let result = offsetCoordinate(latitude: origin.lat, longitude: origin.lon, bearing: 0, distance: 100)
        let dist = haversineDistance(lat1: origin.lat, lon1: origin.lon, lat2: result.lat, lon2: result.lon)
        XCTAssertEqual(dist, 100, accuracy: 0.5) // within 0.5 m
    }

    func testHighLatitudeOffset() {
        // Near the Arctic — geometry is compressed but should still work
        let result = offsetCoordinate(latitude: 80, longitude: 15, bearing: .pi / 4, distance: 500)
        let dist = haversineDistance(lat1: 80, lon1: 15, lat2: result.lat, lon2: result.lon)
        XCTAssertEqual(dist, 500, accuracy: 1.0)
    }

    // MARK: - haversineDistance

    func testHaversineZeroForSamePoint() {
        let dist = haversineDistance(lat1: 48.8566, lon1: 2.3522, lat2: 48.8566, lon2: 2.3522)
        XCTAssertEqual(dist, 0, accuracy: 0.001)
    }

    func testHaversineKnownDistance() {
        // London (51.5074, -0.1278) to Paris (48.8566, 2.3522) ≈ 340 km
        let dist = haversineDistance(lat1: 51.5074, lon1: -0.1278, lat2: 48.8566, lon2: 2.3522)
        XCTAssertEqual(dist, 340_000, accuracy: 5_000) // within 5 km
    }

    func testHaversineSymmetric() {
        let a = haversineDistance(lat1: 37.77, lon1: -122.42, lat2: 34.05, lon2: -118.24)
        let b = haversineDistance(lat1: 34.05, lon1: -118.24, lat2: 37.77, lon2: -122.42)
        XCTAssertEqual(a, b, accuracy: 0.001)
    }

    // MARK: - fuzzedCoordinate (random, bounds check)

    func testFuzz10mStaysWithinRadius() {
        assertFuzzStaysWithin(lat: 51.5074, lon: -0.1278, radius: 10, iterations: 200)
    }

    func testFuzz50mStaysWithinRadius() {
        assertFuzzStaysWithin(lat: 40.7128, lon: -74.0060, radius: 50, iterations: 200)
    }

    func testFuzz200mStaysWithinRadius() {
        assertFuzzStaysWithin(lat: 35.6762, lon: 139.6503, radius: 200, iterations: 200)
    }

    func testFuzzZeroRadiusReturnsOrigin() {
        let result = fuzzedCoordinate(latitude: 51.5, longitude: -0.12, radiusMeters: 0)
        XCTAssertEqual(result.lat, 51.5, accuracy: 1e-10)
        XCTAssertEqual(result.lon, -0.12, accuracy: 1e-10)
    }

    func testFuzzProducesDifferentResultsEachCall() {
        // Two calls should almost never produce identical output
        let a = fuzzedCoordinate(latitude: 51.5, longitude: -0.12, radiusMeters: 200)
        let b = fuzzedCoordinate(latitude: 51.5, longitude: -0.12, radiusMeters: 200)
        // Not strictly guaranteed, but probability of exact match is astronomically low
        let identical = (a.lat == b.lat && a.lon == b.lon)
        XCTAssertFalse(identical, "Two independent fuzz calls should not produce identical coordinates")
    }

    // MARK: - Helpers

    private func assertFuzzStaysWithin(lat: Double, lon: Double, radius: Double, iterations: Int) {
        for _ in 0..<iterations {
            let result = fuzzedCoordinate(latitude: lat, longitude: lon, radiusMeters: radius)
            let dist = haversineDistance(lat1: lat, lon1: lon, lat2: result.lat, lon2: result.lon)
            XCTAssertLessThanOrEqual(dist, radius + 0.01, // +0.01 m floating-point tolerance
                "Fuzzed coordinate \(dist)m from origin exceeds radius \(radius)m")
        }
    }
}
