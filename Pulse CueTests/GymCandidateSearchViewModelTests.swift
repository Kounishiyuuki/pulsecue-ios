//
//  GymCandidateSearchViewModelTests.swift
//  Pulse CueTests
//
//  Drives every state-machine branch of the candidate search VM via
//  `FakeGymCandidateSearchService`. No MapKit / network involved.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct GymCandidateSearchViewModelTests {

    // MARK: - Initial state

    @Test
    func startsIdleWithBothFieldsEmpty() {
        let vm = GymCandidateSearchViewModel(
            service: FakeGymCandidateSearchService.returning([])
        )
        #expect(vm.state == .idle)
        #expect(vm.brand.isEmpty)
        #expect(vm.branch.isEmpty)
        #expect(vm.canSearch == false)
    }

    // MARK: - canSearch

    @Test
    func cannotSearchWhenBothFieldsAreBlank() {
        let vm = GymCandidateSearchViewModel(
            service: FakeGymCandidateSearchService.returning([])
        )
        vm.brand = "   "
        vm.branch = "\n\t"
        #expect(vm.canSearch == false)
    }

    @Test
    func canSearchWithBrandOnly() {
        let vm = GymCandidateSearchViewModel(
            service: FakeGymCandidateSearchService.returning([])
        )
        vm.brand = "エニタイム"
        #expect(vm.canSearch == true)
    }

    @Test
    func canSearchWithBranchOnly() {
        let vm = GymCandidateSearchViewModel(
            service: FakeGymCandidateSearchService.returning([])
        )
        vm.branch = "金沢"
        #expect(vm.canSearch == true)
    }

    // MARK: - Result states

    @Test
    func loadedStateWhenServiceReturnsCandidates() async {
        let canned = FakeGymCandidateSearchService.previewCandidates
        let vm = GymCandidateSearchViewModel(
            service: FakeGymCandidateSearchService.returning(canned)
        )
        vm.brand = "エニタイムフィットネス"
        vm.branch = "金沢"
        await vm.searchSync()
        guard case .loaded(let results) = vm.state else {
            Issue.record("expected .loaded, got \(vm.state)")
            return
        }
        #expect(results.count == canned.count)
        #expect(results.first?.name == canned.first?.name)
    }

    @Test
    func emptyStateWhenServiceReturnsEmptyArray() async {
        let vm = GymCandidateSearchViewModel(
            service: FakeGymCandidateSearchService.returning([])
        )
        vm.brand = "存在しないジム名123"
        await vm.searchSync()
        #expect(vm.state == .empty)
    }

    @Test
    func errorStateOnQuotaExceeded() async {
        let vm = GymCandidateSearchViewModel(
            service: FakeGymCandidateSearchService.throwing(.quotaExceeded)
        )
        vm.brand = "ゴールドジム"
        await vm.searchSync()
        guard case .error(let message) = vm.state else {
            Issue.record("expected .error, got \(vm.state)")
            return
        }
        #expect(message.contains("上限"))
    }

    @Test
    func errorStateOnTransportFailure() async {
        let vm = GymCandidateSearchViewModel(
            service: FakeGymCandidateSearchService.throwing(.transport("offline"))
        )
        vm.brand = "ゴールドジム"
        await vm.searchSync()
        if case .error = vm.state {
            // ok
        } else {
            Issue.record("expected .error, got \(vm.state)")
        }
    }

    // MARK: - Reset

    @Test
    func resetReturnsToIdleFromAnyState() async {
        let vm = GymCandidateSearchViewModel(
            service: FakeGymCandidateSearchService.returning([])
        )
        vm.brand = "x"
        await vm.searchSync()
        #expect(vm.state == .empty)
        vm.reset()
        #expect(vm.state == .idle)
    }

    // MARK: - Query builder

    @Test
    func queryBuilderConcatenatesBothFields() {
        let query = GymCandidateQueryBuilder.makeQuery(brand: "エニタイム", branch: "金沢")
        #expect(query == "エニタイム 金沢")
    }

    @Test
    func queryBuilderTrimsWhitespace() {
        let query = GymCandidateQueryBuilder.makeQuery(
            brand: "  エニタイム  ",
            branch: "\n金沢駅西\t"
        )
        #expect(query == "エニタイム 金沢駅西")
    }

    @Test
    func queryBuilderHandlesSingleFieldOnly() {
        #expect(GymCandidateQueryBuilder.makeQuery(brand: "ゴールドジム", branch: "") == "ゴールドジム")
        #expect(GymCandidateQueryBuilder.makeQuery(brand: "", branch: "金沢") == "金沢")
    }

    @Test
    func queryBuilderReturnsEmptyForBothBlank() {
        #expect(GymCandidateQueryBuilder.makeQuery(brand: "  ", branch: " \n").isEmpty)
    }

    // MARK: - Candidate helpers

    @Test
    func candidateHostnameStripsScheme() {
        let candidate = GymCandidate(
            name: "x",
            address: "y",
            officialUrlString: "https://www.example.co.jp/path?q=1",
            sourceLabel: "fake"
        )
        #expect(candidate.hostnameForDisplay == "example.co.jp")
    }

    @Test
    func candidateHostnameIsNilWhenNoUrl() {
        let candidate = GymCandidate(name: "x", address: "y", sourceLabel: "fake")
        #expect(candidate.hostnameForDisplay == nil)
    }
}
