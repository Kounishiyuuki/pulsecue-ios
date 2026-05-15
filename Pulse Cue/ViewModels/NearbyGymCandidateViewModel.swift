//
//  NearbyGymCandidateViewModel.swift
//  Pulse Cue
//
//  State machine for the "現在地から近くのジムを探す" flow.
//  Permission is requested only on the user's explicit tap — never on
//  view appear or app launch. CoreLocation and MapKit are both behind
//  protocols so the test suite drives every branch with fakes.
//

import CoreLocation
import Combine
import Foundation

@MainActor
final class NearbyGymCandidateViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case permissionDenied
        case locating
        case searching
        case loaded([GymCandidate])
        case empty
        case error(String)
    }

    @Published private(set) var state: State = .idle

    private let locationProvider: LocationProvider
    private let searchService: NearbyGymCandidateSearchService
    private let radiusMeters: CLLocationDistance

    init(
        locationProvider: LocationProvider,
        searchService: NearbyGymCandidateSearchService,
        radiusMeters: CLLocationDistance = 2_000
    ) {
        self.locationProvider = locationProvider
        self.searchService = searchService
        self.radiusMeters = radiusMeters
    }

    /// Single entry point. Handles permission, coordinate fetch and
    /// nearby search in one async sequence; failures at any step set
    /// a terminal state the view can render.
    func searchNearby() async {
        let initialStatus = locationProvider.authorizationStatus
        switch initialStatus {
        case .denied, .restricted:
            state = .permissionDenied
            return
        case .notDetermined:
            state = .locating
            let granted = await locationProvider.requestPermission()
            guard granted == .authorizedWhenInUse || granted == .authorizedAlways else {
                state = .permissionDenied
                return
            }
        case .authorizedWhenInUse, .authorizedAlways:
            state = .locating
        @unknown default:
            state = .permissionDenied
            return
        }

        do {
            let coordinate = try await locationProvider.currentLocation().coordinate
            state = .searching
            let candidates = try await searchService.searchNearby(
                coordinate: coordinate,
                radiusMeters: radiusMeters
            )
            state = candidates.isEmpty ? .empty : .loaded(candidates)
        } catch let error as LocationProviderError {
            if error == .unauthorized {
                state = .permissionDenied
            } else {
                state = .error(error.errorDescription ?? "位置情報の取得に失敗しました。")
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            state = .error(message)
        }
    }

    func reset() {
        state = .idle
    }
}
