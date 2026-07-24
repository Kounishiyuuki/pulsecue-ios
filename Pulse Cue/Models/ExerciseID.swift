//
//  ExerciseID.swift
//  Pulse Cue
//
//  A lightweight, non-persistent stable identity for a *movement*
//  (exercise), kept deliberately separate from equipment identity.
//
//    - equipment: `cable_machine`  (MachineCatalog / GymMachine / CustomMachine)
//    - exercise:  `cable_triceps_pushdown`  (this type)
//
//  One equipment item can support several exercises, and one exercise can
//  be performed on more than one compatible equipment. `ExerciseID` is:
//   - a plain value type (NOT a SwiftData `@Model`, no annotation),
//   - stable across display-name / localization / animation changes,
//   - independent of any `GymMachine` / `CustomMachine` instance,
//   - a stable string suitable for planner references, guide lookup, and
//     a future AI allowlist contract.
//
//  It is NOT a UUID: bundled standard exercises use readable snake_case
//  ids so plans, tests, and future analytics stay legible.
//

import Foundation

/// Stable identity of a standard exercise movement.
///
/// The raw value must be lowercase ASCII snake_case
/// (`^[a-z0-9]+(?:_[a-z0-9]+)*$`); this is enforced by
/// `ExerciseLibraryTests`, not at runtime, so an authoring mistake fails a
/// test rather than crashing the app.
struct ExerciseID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Terse literal-style initializer for the static library table.
    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    /// Regex the library authoring must satisfy. Exposed so a single test
    /// is the one source of truth for the format rule.
    static let formatPattern = "^[a-z0-9]+(?:_[a-z0-9]+)*$"

    /// Pure format check (no library membership). Useful for the future
    /// AI contract, which must reject anything that is not a well-formed id
    /// before it is even looked up.
    var isWellFormed: Bool {
        rawValue.range(of: Self.formatPattern, options: .regularExpression) != nil
    }
}

extension ExerciseID: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.rawValue = value
    }
}

extension ExerciseID: Identifiable {
    /// Stable identity for SwiftUI `sheet(item:)` presentation.
    var id: String { rawValue }
}

/// How an `Exercise` relates to equipment. Standard exercises reference an
/// exact `MachineCatalog` id; the type-based case exists for genuinely
/// generic movements but is unused by the current bundled data (kept small,
/// not speculative — it costs nothing and documents the intended shape for
/// the equipment-compatibility validation test).
enum ExerciseEquipment: Hashable, Sendable {
    /// An exact `MachineCatalog` entry id (e.g. `lat_pulldown`).
    case machine(String)
    /// Any equipment of a given type. Not used by bundled data yet.
    case anyOfType(EquipmentType)

    /// The exact catalog id this compatibility refers to, when it is an
    /// exact-machine reference. `nil` for type-based compatibility.
    var machineId: String? {
        if case let .machine(id) = self { return id }
        return nil
    }
}
