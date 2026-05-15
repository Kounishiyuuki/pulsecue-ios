//
//  NearbyGymCandidateViewModelTests.swift
//  Pulse CueTests
//
//  Drives every state-machine branch of the nearby-gym VM through
//  `FakeLocationProvider` + `FakeNearbyGymCandidateSearchService`.
//  No CoreLocation / MapKit / network involved.
//

import CoreLocation
import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct NearbyGymCandidateViewModelTests {

    private static func makeCandidate(_ name: String) -> GymCandidate {
        GymCandidate(
            name: name,
            address: "金沢市 駅西本町 1-1-1",
            officialUrlString: nil,
            sourceLabel: "Fake"
        )
    }

    // MARK: - Initial

    @Test
    func startsIdle() {
        let vm = NearbyGymCandidateViewModel(
            locationProvider: FakeLocationProvider(initialStatus: .authorizedWhenInUse),
            searchService: FakeNearbyGymCandidateSearchService.returning([])
        )
        #expect(vm.state == .idle)
    }

    // MARK: - Permission

    @Test
    func deniedPermissionGoesStraightToPermissionDenied() async {
        let vm = NearbyGymCandidateViewModel(
            locationProvider: FakeLocationProvider(initialStatus: .denied),
            searchService: FakeNearbyGymCandidateSearchService.returning([Self.makeCandidate("x")])
        )
        await vm.searchNearby()
        #expect(vm.state == .permissionDenied)
    }

    @Test
    func restrictedPermissionGoesStraightToPermissionDenied() async {
        let vm = NearbyGymCandidateViewModel(
            locationProvider: FakeLocationProvider(initialStatus: .restricted),
            searchService: FakeNearbyGymCandidateSearchService.returning([Self.makeCandidate("x")])
        )
        await vm.searchNearby()
        #expect(vm.state == .permissionDenied)
    }

    @Test
    func notDeterminedThenDenyEndsAtPermissionDenied() async {
        let provider = FakeLocationProvider(
            initialStatus: .notDetermined,
            afterPromptStatus: .denied
        )
        let vm = NearbyGymCandidateViewModel(
            locationProvider: provider,
            searchService: FakeNearbyGymCandidateSearchService.returning([Self.makeCandidate("x")])
        )
        await vm.searchNearby()
        #expect(vm.state == .permissionDenied)
        #expect(provider.requestPermissionCalls == 1)
    }

    @Test
    func notDeterminedThenAllowProceedsToLoaded() async {
        let provider = FakeLocationProvider(
            initialStatus: .notDetermined,
            afterPromptStatus: .authorizedWhenInUse
        )
        let vm = NearbyGymCandidateViewModel(
            locationProvider: provider,
            searchService: FakeNearbyGymCandidateSearchService.returning([Self.makeCandidate("Anytime")])
        )
        await vm.searchNearby()
        guard case .loaded(let candidates) = vm.state else {
            Issue.record("expected .loaded, got \(vm.state)")
            return
        }
        #expect(candidates.count == 1)
        #expect(provider.requestPermissionCalls == 1)
    }

    // MARK: - Happy / empty / error

    @Test
    func authorizedHappyPathReturnsLoaded() async {
        let vm = NearbyGymCandidateViewModel(
            locationProvider: FakeLocationProvider(initialStatus: .authorizedWhenInUse),
            searchService: FakeNearbyGymCandidateSearchService.returning([
                Self.makeCandidate("ゴールドジム 金沢"),
                Self.makeCandidate("エニタイムフィットネス 金沢駅西"),
            ])
        )
        await vm.searchNearby()
        guard case .loaded(let candidates) = vm.state else {
            Issue.record("expected .loaded, got \(vm.state)")
            return
        }
        #expect(candidates.count == 2)
    }

    @Test
    func emptyResultEndsInEmptyState() async {
        let vm = NearbyGymCandidateViewModel(
            locationProvider: FakeLocationProvider(initialStatus: .authorizedWhenInUse),
            searchService: FakeNearbyGymCandidateSearchService.returning([])
        )
        await vm.searchNearby()
        #expect(vm.state == .empty)
    }

    @Test
    func locationFailureEndsInErrorState() async {
        let provider = FakeLocationProvider(
            initialStatus: .authorizedWhenInUse,
            locationResult: .failure(LocationProviderError.unavailable("simulator has no fix"))
        )
        let vm = NearbyGymCandidateViewModel(
            locationProvider: provider,
            searchService: FakeNearbyGymCandidateSearchService.returning([Self.makeCandidate("x")])
        )
        await vm.searchNearby()
        if case .error = vm.state {
            // ok
        } else {
            Issue.record("expected .error, got \(vm.state)")
        }
    }

    @Test
    func revokedPermissionDuringLocationFetchYieldsPermissionDenied() async {
        let provider = FakeLocationProvider(
            initialStatus: .authorizedWhenInUse,
            locationResult: .failure(LocationProviderError.unauthorized)
        )
        let vm = NearbyGymCandidateViewModel(
            locationProvider: provider,
            searchService: FakeNearbyGymCandidateSearchService.returning([Self.makeCandidate("x")])
        )
        await vm.searchNearby()
        #expect(vm.state == .permissionDenied)
    }

    @Test
    func searchFailureSurfacesAsError() async {
        let vm = NearbyGymCandidateViewModel(
            locationProvider: FakeLocationProvider(initialStatus: .authorizedWhenInUse),
            searchService: FakeNearbyGymCandidateSearchService.throwing(
                GymCandidateSearchError.transport("offline")
            )
        )
        await vm.searchNearby()
        if case .error = vm.state {
            // ok
        } else {
            Issue.record("expected .error, got \(vm.state)")
        }
    }

    @Test
    func quotaExceededSurfacesLocalizedMessage() async {
        let vm = NearbyGymCandidateViewModel(
            locationProvider: FakeLocationProvider(initialStatus: .authorizedWhenInUse),
            searchService: FakeNearbyGymCandidateSearchService.throwing(
                GymCandidateSearchError.quotaExceeded
            )
        )
        await vm.searchNearby()
        guard case .error(let message) = vm.state else {
            Issue.record("expected .error, got \(vm.state)")
            return
        }
        #expect(message.contains("上限"))
    }

    // MARK: - Reset

    @Test
    func resetReturnsToIdle() async {
        let vm = NearbyGymCandidateViewModel(
            locationProvider: FakeLocationProvider(initialStatus: .denied),
            searchService: FakeNearbyGymCandidateSearchService.returning([])
        )
        await vm.searchNearby()
        #expect(vm.state == .permissionDenied)
        vm.reset()
        #expect(vm.state == .idle)
    }
}
