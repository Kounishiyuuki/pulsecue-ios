//
//  GymCandidateSearchService.swift
//  Pulse Cue
//
//  Protocol abstraction for "given a brand and a branch/location,
//  return a small list of gym candidates the user can pick from".
//  Today the only production impl is `MapKitGymCandidateSearchService`
//  (MKLocalSearch) and the test/preview impl is
//  `FakeGymCandidateSearchService`. The protocol exists so the search
//  ViewModel never imports MapKit directly — keeping it pure makes
//  state-machine tests trivial.
//

import Foundation

protocol GymCandidateSearchService {
    /// Returns up to a small number of candidates ranked by the
    /// underlying source's relevance. Implementations should throw a
    /// `GymCandidateSearchError` for any failure surface the UI cares
    /// about.
    func search(brand: String, branch: String) async throws -> [GymCandidate]
}

enum GymCandidateSearchError: LocalizedError, Equatable {
    /// Caller passed an empty query (both brand and branch blank).
    case unsupportedQuery
    /// Underlying source reached a rate or quota limit.
    case quotaExceeded
    /// Network / transport failure (e.g. no connectivity).
    case transport(String)
    /// Unexpected source failure that doesn't fit the other cases.
    case other(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedQuery:
            return "検索キーワードを入力してください。"
        case .quotaExceeded:
            return "検索回数の上限に達しました。しばらく待ってからやり直してください。"
        case .transport(let message):
            return "検索に失敗しました。ネットワーク状態を確認するか、手動で入力してください。(\(message))"
        case .other(let message):
            return "検索に失敗しました。手動で入力してください。(\(message))"
        }
    }
}

/// Normalizes the user's two input fields into a single
/// MKLocalSearch-style natural-language query. Public/testable so the
/// ViewModel doesn't have to know how to assemble it.
enum GymCandidateQueryBuilder {
    static func makeQuery(brand: String, branch: String) -> String {
        let brandPart = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchPart = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (brandPart.isEmpty, branchPart.isEmpty) {
        case (true, true): return ""
        case (false, true): return brandPart
        case (true, false): return branchPart
        case (false, false): return "\(brandPart) \(branchPart)"
        }
    }
}
