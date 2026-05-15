//
//  FakeGymCandidateSearchService.swift
//  Pulse Cue
//
//  Deterministic test/preview implementation of
//  `GymCandidateSearchService`. The default behavior returns a small
//  canned list; tests can swap in a closure to drive every
//  state-machine branch (`empty`, `error`, `quotaExceeded`, etc.)
//  without going through MapKit.
//

import Foundation

struct FakeGymCandidateSearchService: GymCandidateSearchService {
    var handler: (_ brand: String, _ branch: String) async throws -> [GymCandidate]

    init(handler: @escaping (_ brand: String, _ branch: String) async throws -> [GymCandidate]) {
        self.handler = handler
    }

    func search(brand: String, branch: String) async throws -> [GymCandidate] {
        try await handler(brand, branch)
    }

    // MARK: - Convenience constructors

    /// Returns the given fixed list, regardless of input.
    static func returning(_ candidates: [GymCandidate]) -> FakeGymCandidateSearchService {
        FakeGymCandidateSearchService { _, _ in candidates }
    }

    /// Always throws the given error.
    static func throwing(_ error: GymCandidateSearchError) -> FakeGymCandidateSearchService {
        FakeGymCandidateSearchService { _, _ in throw error }
    }

    /// Two plausible chain results for previews.
    static var previewCandidates: [GymCandidate] {
        [
            GymCandidate(
                name: "エニタイムフィットネス 金沢駅西店",
                address: "金沢市 駅西本町 1-1-1",
                officialUrlString: "https://www.anytimefitness.co.jp/kanazawa-ekinishi/",
                phoneNumber: nil,
                sourceLabel: "Apple マップ"
            ),
            GymCandidate(
                name: "エニタイムフィットネス 野々市店",
                address: "野々市市 三日市 2-2-2",
                officialUrlString: nil,
                phoneNumber: nil,
                sourceLabel: "Apple マップ"
            ),
        ]
    }
}
