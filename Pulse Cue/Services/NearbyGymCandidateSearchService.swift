//
//  NearbyGymCandidateSearchService.swift
//  Pulse Cue
//
//  Coordinate-based gym search abstraction. The text-search flow in
//  PR #21 uses `MKLocalSearch.Request` with a natural-language query;
//  this one uses `MKLocalPointsOfInterestRequest(center:radius:)`
//  which is the right MapKit shape for "everything tagged as fitness
//  near this point." Kept as a separate protocol so each implementation
//  stays narrow and easy to fake.
//

import CoreLocation
import Foundation

protocol NearbyGymCandidateSearchService {
    func searchNearby(
        coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance
    ) async throws -> [GymCandidate]
}
