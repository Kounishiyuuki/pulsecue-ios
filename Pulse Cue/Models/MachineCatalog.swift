//
//  MachineCatalog.swift
//  Pulse Cue
//
//  Canonical list of gym machines the app recognizes. Mirrors the
//  server-side catalog at `server/src/parser/machines.ts` for the
//  manual-selection MVP — they MUST stay in sync. A follow-up will
//  fetch this list from a `/api/machines/catalog` endpoint so iOS and
//  the server agree by construction; until then a unit test asserts
//  the local catalog id list is sorted and has no duplicates so any
//  drift shows up in a PR diff.
//
//  This file deliberately stays a value-only catalog. It does not
//  depend on SwiftData; persisted `GymMachine` rows denormalize the
//  display name at save time so renames here don't silently mutate
//  the user's saved data.
//

import Foundation

/// Coarse grouping used by future UI filters and the rule-based plan
/// generator. Mirrors `BodyPart` but kept as its own type so we can
/// evolve filtering (e.g. add `mobility`) without touching the persisted
/// `BodyPart` enum that already ships in saved data.
enum MachineCategory: String, Hashable, CaseIterable, Sendable {
    case chest, back, shoulders, arms, legs, core, cardio, fullBody
}

/// How the user interacts with the equipment. Useful for filtering when
/// a gym lacks certain gear, or when building beginner-friendly plans.
enum EquipmentType: String, Hashable, CaseIterable, Sendable {
    case machine, cable, freeWeight, bodyweight, cardioMachine
}

/// Primary movement pattern. Used by the future weekly plan generator
/// to balance push/pull and avoid stacking redundant patterns.
enum MovementPattern: String, Hashable, CaseIterable, Sendable {
    case push, pull, squat, hinge, lunge, carry, core, cardio
}

enum MachineDifficulty: String, Hashable, CaseIterable, Sendable {
    case beginner, intermediate, advanced
}

struct MachineCatalogEntry: Identifiable, Hashable {
    /// Canonical id matching the server catalog (e.g. `lat_pulldown`).
    let id: String
    /// User-facing Japanese label.
    let displayName: String
    /// Body parts this machine primarily trains. Used by the plan
    /// generator to filter candidate machines.
    let bodyParts: Set<BodyPart>

    // MARK: - Optional metadata (see Docs/gym-machine-catalog-and-plan-foundation.md §4)
    //
    // All fields below are optional / defaulted so existing catalog
    // entries compile unchanged and can be enriched gradually in later
    // PRs without breaking call sites.

    /// Primary category, typically the representative member of `bodyParts`.
    let category: MachineCategory?
    let equipmentType: EquipmentType?
    let movementPattern: MovementPattern?
    let difficulty: MachineDifficulty?
    let beginnerFriendly: Bool?
    /// Stable-ordered list of secondary muscle groups. Array (not Set)
    /// because catalog data is hand-written and we want diff-friendly
    /// ordering.
    let secondaryMuscles: [BodyPart]
    let setupNotes: String?
    let safetyNotes: String?
    let defaultSets: Int?
    /// Inclusive rep range the generator can sample from when it has no
    /// stronger signal. `nil` means "fall back to the generator's own
    /// template table".
    let defaultReps: ClosedRange<Int>?
    let defaultRestSeconds: Int?
    /// Free-form tags (e.g. "compound", "barbell"). Kept as an array so
    /// authoring order survives in PR diffs.
    let tags: [String]

    init(
        id: String,
        displayName: String,
        bodyParts: Set<BodyPart>,
        category: MachineCategory? = nil,
        equipmentType: EquipmentType? = nil,
        movementPattern: MovementPattern? = nil,
        difficulty: MachineDifficulty? = nil,
        beginnerFriendly: Bool? = nil,
        secondaryMuscles: [BodyPart] = [],
        setupNotes: String? = nil,
        safetyNotes: String? = nil,
        defaultSets: Int? = nil,
        defaultReps: ClosedRange<Int>? = nil,
        defaultRestSeconds: Int? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.bodyParts = bodyParts
        self.category = category
        self.equipmentType = equipmentType
        self.movementPattern = movementPattern
        self.difficulty = difficulty
        self.beginnerFriendly = beginnerFriendly
        self.secondaryMuscles = secondaryMuscles
        self.setupNotes = setupNotes
        self.safetyNotes = safetyNotes
        self.defaultSets = defaultSets
        self.defaultReps = defaultReps
        self.defaultRestSeconds = defaultRestSeconds
        self.tags = tags
    }
}

enum MachineCatalog {
    /// All known machines, sorted by `id` to keep PR diffs stable and
    /// to make the "no duplicate ids" test trivial.
    static let all: [MachineCatalogEntry] = [
        MachineCatalogEntry(id: "back_extension", displayName: "バックエクステンション", bodyParts: [.back, .core]),
        MachineCatalogEntry(id: "bench_press", displayName: "ベンチプレス", bodyParts: [.chest, .arms]),
        MachineCatalogEntry(id: "bike", displayName: "エアロバイク", bodyParts: [.fullBody, .legs]),
        MachineCatalogEntry(id: "cable_machine", displayName: "ケーブルマシン", bodyParts: [.back, .chest, .arms, .shoulders]),
        MachineCatalogEntry(id: "chest_press", displayName: "チェストプレス", bodyParts: [.chest, .arms]),
        MachineCatalogEntry(id: "dumbbells", displayName: "ダンベル", bodyParts: [.chest, .back, .shoulders, .arms]),
        MachineCatalogEntry(id: "lat_pulldown", displayName: "ラットプルダウン", bodyParts: [.back, .arms]),
        MachineCatalogEntry(id: "leg_curl", displayName: "レッグカール", bodyParts: [.legs]),
        MachineCatalogEntry(id: "leg_extension", displayName: "レッグエクステンション", bodyParts: [.legs]),
        MachineCatalogEntry(id: "leg_press", displayName: "レッグプレス", bodyParts: [.legs]),
        MachineCatalogEntry(id: "pec_deck", displayName: "ペックデック", bodyParts: [.chest]),
        MachineCatalogEntry(id: "pull_up_bar", displayName: "プルアップバー", bodyParts: [.back, .arms]),
        MachineCatalogEntry(id: "seated_row", displayName: "シーテッドロー", bodyParts: [.back, .arms]),
        MachineCatalogEntry(id: "shoulder_press", displayName: "ショルダープレス", bodyParts: [.shoulders, .arms]),
        MachineCatalogEntry(id: "smith_machine", displayName: "スミスマシン", bodyParts: [.chest, .legs, .shoulders]),
        MachineCatalogEntry(id: "treadmill", displayName: "トレッドミル", bodyParts: [.fullBody, .legs]),
    ]

    /// O(1) lookup by canonical id. Returns nil for ids that aren't in
    /// the catalog (e.g. older saved rows after a catalog rename).
    static func entry(for machineId: String) -> MachineCatalogEntry? {
        index[machineId]
    }

    /// Machines that train the given body part, in catalog order.
    static func entries(for bodyPart: BodyPart) -> [MachineCatalogEntry] {
        all.filter { $0.bodyParts.contains(bodyPart) }
    }

    private static let index: [String: MachineCatalogEntry] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }()
}
