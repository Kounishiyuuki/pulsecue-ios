//
//  FakeNearbyGymCandidateSearchService.swift
//  Pulse Cue
//
//  Deterministic test/preview impl. Mirrors the shape of
//  `FakeGymCandidateSearchService` (PR #21) so callers can drive every
//  state-machine branch without touching MapKit.
//

import CoreLocation
import Foundation

struct FakeNearbyGymCandidateSearchService: NearbyGymCandidateSearchService {
    var handler: (_ coordinate: CLLocationCoordinate2D, _ radiusMeters: CLLocationDistance) async throws -> [GymCandidate]

    init(handler: @escaping (_ coordinate: CLLocationCoordinate2D, _ radiusMeters: CLLocationDistance) async throws -> [GymCandidate]) {
        self.handler = handler
    }

    func searchNearby(
        coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance
    ) async throws -> [GymCandidate] {
        try await handler(coordinate, radiusMeters)
    }

    static func returning(_ candidates: [GymCandidate]) -> FakeNearbyGymCandidateSearchService {
        FakeNearbyGymCandidateSearchService { _, _ in candidates }
    }

    static func throwing(_ error: Error) -> FakeNearbyGymCandidateSearchService {
        FakeNearbyGymCandidateSearchService { _, _ in throw error }
    }
}
