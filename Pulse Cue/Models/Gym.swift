//
//  Gym.swift
//  Pulse Cue
//
//  SwiftData row for a registered gym. The active gym is the one the
//  workout plan generator targets; the "single active gym" invariant
//  is enforced by `GymRepository.setActive(_:)`, not by the schema,
//  because SwiftData has no compound unique constraint that lets us
//  express "at most one row where isActive == true" directly.
//
//  Machines belonging to a gym are stored as `GymMachine` rows with a
//  `gymId` foreign key, matching the existing `Routine`/`Step`
//  normalized pattern in this project. There is no `@Relationship`.
//

import Foundation
import SwiftData

@Model
final class Gym {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Stored as a plain `String?` because SwiftData treats `URL?` as
    /// a transformable; keeping it text simplifies migrations and
    /// matches what the import flow will eventually send to the
    /// server. Validation lives at input time, not at the model.
    var officialUrl: String?
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        officialUrl: String? = nil,
        isActive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.isEmpty ? "無題のジム" : name
        self.officialUrl = Gym.normalize(officialUrl)
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Trims whitespace and returns nil for empty input so the UI can
    /// treat "未設定" and "空文字" the same way.
    static func normalize(_ input: String?) -> String? {
        guard let input else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
