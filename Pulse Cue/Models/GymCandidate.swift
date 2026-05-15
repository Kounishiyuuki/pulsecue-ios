//
//  GymCandidate.swift
//  Pulse Cue
//
//  Plain value type returned by `GymCandidateSearchService`. Holds
//  everything the candidate-search UI needs to render one result row
//  and pre-fill `GymRegistrationView` when the user picks it. Lives
//  outside SwiftData on purpose — candidates are transient search
//  output, not persisted state.
//

import Foundation

struct GymCandidate: Identifiable, Hashable {
    /// Local identifier for SwiftUI diffing only; not persisted.
    let id: UUID
    let name: String
    let address: String
    let officialUrlString: String?
    let phoneNumber: String?
    /// Where this candidate came from. Today only "Apple マップ"; kept
    /// as plain text so future service implementations can label their
    /// own results without us needing an enum.
    let sourceLabel: String

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        officialUrlString: String? = nil,
        phoneNumber: String? = nil,
        sourceLabel: String
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.officialUrlString = officialUrlString
        self.phoneNumber = phoneNumber
        self.sourceLabel = sourceLabel
    }

    /// Hostname only, useful for compact pill display
    /// ("example.com" instead of "https://example.com/foo").
    var hostnameForDisplay: String? {
        guard let officialUrlString,
              let url = URL(string: officialUrlString),
              let host = url.host?.lowercased()
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
