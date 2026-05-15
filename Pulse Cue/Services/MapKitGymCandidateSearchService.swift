//
//  MapKitGymCandidateSearchService.swift
//  Pulse Cue
//
//  Production `GymCandidateSearchService` backed by `MKLocalSearch`.
//  Deliberately does **not** request user location — biasing by the
//  user's coordinates would force a new permission prompt, so MVP
//  searches against Apple's global map index using only the natural
//  language query the user typed. Results trade some precision for
//  zero new permissions and zero device-side API key.
//

import Foundation
import MapKit

struct MapKitGymCandidateSearchService: GymCandidateSearchService {

    private let sourceLabel: String
    private let resultLimit: Int

    init(sourceLabel: String = "Apple マップ", resultLimit: Int = 8) {
        self.sourceLabel = sourceLabel
        self.resultLimit = resultLimit
    }

    func search(brand: String, branch: String) async throws -> [GymCandidate] {
        let query = GymCandidateQueryBuilder.makeQuery(brand: brand, branch: branch)
        guard !query.isEmpty else {
            throw GymCandidateSearchError.unsupportedQuery
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // `.pointOfInterest` filters out raw address rows so we only
        // surface businesses. We intentionally do NOT set
        // `pointOfInterestFilter` — restricting to `.fitnessCenter`
        // alone misses chain branches that Apple has classified under
        // other categories, and tap-to-search keeps quota use modest.
        request.resultTypes = .pointOfInterest

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
                name: item.name ?? query,
                address: Self.formatAddress(item.placemark),
                officialUrlString: item.url?.absoluteString,
                phoneNumber: item.phoneNumber,
                sourceLabel: sourceLabel
            )
        }
    }

    /// Builds a single-line address out of the placemark fields most
    /// useful in Japan (locality / thoroughfare / subThoroughfare).
    /// Falls back to `placemark.title` when none are available.
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
