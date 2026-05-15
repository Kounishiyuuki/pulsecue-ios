//
//  MapKitNearbyGymCandidateSearchService.swift
//  Pulse Cue
//
//  Production nearby search using `MKLocalPointsOfInterestRequest`.
//  Unlike the text-search service in PR #21, this one filters by POI
//  category (fitness center) instead of natural-language query, so we
//  surface gyms that exist nearby even when the user can't name them.
//
//  Address formatting mirrors `MapKitGymCandidateSearchService` for
//  consistency; the small duplication is intentional to keep PR #21's
//  file unchanged in this PR.
//

import CoreLocation
import Foundation
import MapKit

struct MapKitNearbyGymCandidateSearchService: NearbyGymCandidateSearchService {

    private let sourceLabel: String
    private let resultLimit: Int

    init(sourceLabel: String = "Apple マップ", resultLimit: Int = 12) {
        self.sourceLabel = sourceLabel
        self.resultLimit = resultLimit
    }

    func searchNearby(
        coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance
    ) async throws -> [GymCandidate] {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: radiusMeters)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.fitnessCenter])

        let search = MKLocalSearch(request: request)
        let response: MKLocalSearch.Response
        do {
            response = try await search.start()
        } catch let error as MKError {
            throw map(mkError: error)
        } catch {
            throw GymCandidateSearchError.other(error.localizedDescription)
        }

        return response.mapItems.prefix(resultLimit).map { item in
            GymCandidate(
                name: item.name ?? "名称未取得",
                address: Self.formatAddress(item.placemark),
                officialUrlString: item.url?.absoluteString,
                phoneNumber: item.phoneNumber,
                sourceLabel: sourceLabel
            )
        }
    }

    /// Single-line address built from the placemark fields most useful
    /// in Japan, falling back to the placemark's localized title.
    private static func formatAddress(_ placemark: MKPlacemark) -> String {
        let parts = [placemark.locality, placemark.thoroughfare, placemark.subThoroughfare]
            .compactMap { $0 }
        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return placemark.title ?? ""
    }

    private func map(mkError: MKError) -> GymCandidateSearchError {
        if mkError.code == .loadingThrottled {
            return .quotaExceeded
        }
        return .other(mkError.localizedDescription)
    }
}
