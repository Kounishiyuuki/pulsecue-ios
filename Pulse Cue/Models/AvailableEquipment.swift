//
//  AvailableEquipment.swift
//  Pulse Cue
//
//  One non-persistent representation of "equipment the user can train
//  with", unifying two very different sources:
//
//    - standard: a `GymMachine` row (the user ticked a bundled catalog
//      machine) resolved against `MachineCatalog`,
//    - custom:   a `CustomMachine` row the user authored by hand.
//
//  Deliberately a pure value type:
//   - it is NOT a SwiftData `@Model` and never touches a `ModelContext`,
//   - it performs no I/O — no networking, no persistence, no AI,
//   - it is never persisted; it is rebuilt from the store on demand.
//
//  `MachineCatalogEntry` stays what it always was: the shape of *bundled*
//  catalog data. User-created equipment is NOT converted into a catalog
//  entry, and no catalog metadata is copied into SwiftData. For standard
//  equipment the originating entry is carried along in `catalogEntry` so
//  the planners can keep using the existing catalog-driven behavior
//  unchanged; for custom equipment it is `nil` and the planners fall back
//  to conservative generic values.
//

import Foundation

/// Where a piece of available equipment came from.
enum EquipmentSource: String, Hashable, Sendable {
    case standard
    case custom

    /// Short Japanese label. Only `custom` is surfaced as a badge — the
    /// standard catalog is the unmarked default.
    var badgeLabel: String? {
        switch self {
        case .standard: return nil
        case .custom: return "カスタム"
        }
    }
}

struct AvailableEquipment: Identifiable, Hashable {
    /// Standard: the canonical catalog id (e.g. `lat_pulldown`).
    /// Custom: the derived `custom_<uuid>` reference id.
    let id: String
    let displayName: String
    let bodyParts: Set<BodyPart>
    let equipmentType: EquipmentType?
    let source: EquipmentSource
    /// `nil` when unknown. Beginner-only filtering must treat `nil`
    /// conservatively (i.e. exclude), never optimistically.
    let beginnerFriendly: Bool?
    /// Whether this equipment may enter generated plans.
    let isAvailable: Bool
    /// The bundled catalog entry backing a `.standard` item; `nil` for
    /// custom equipment. Lets the planners preserve existing catalog
    /// behavior without re-deriving it here.
    let catalogEntry: MachineCatalogEntry?
    /// Custom equipment only: the persistent `CustomMachine.id`, so the
    /// UI can edit/delete by UUID rather than by display name.
    let customMachineId: UUID?

    init(
        id: String,
        displayName: String,
        bodyParts: Set<BodyPart>,
        equipmentType: EquipmentType? = nil,
        source: EquipmentSource,
        beginnerFriendly: Bool? = nil,
        isAvailable: Bool = true,
        catalogEntry: MachineCatalogEntry? = nil,
        customMachineId: UUID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bodyParts = bodyParts
        self.equipmentType = equipmentType
        self.source = source
        self.beginnerFriendly = beginnerFriendly
        self.isAvailable = isAvailable
        self.catalogEntry = catalogEntry
        self.customMachineId = customMachineId
    }

    /// Body parts in canonical `BodyPart.allCases` order, so the
    /// (unordered) `Set` renders and compares stably.
    var orderedBodyParts: [BodyPart] {
        BodyPart.allCases.filter { bodyParts.contains($0) }
    }

    var isCustom: Bool { source == .custom }

    // MARK: - Adapters (pure; nothing is persisted here)

    /// Standard equipment from a bundled catalog entry.
    init(entry: MachineCatalogEntry, isAvailable: Bool = true) {
        self.init(
            id: entry.id,
            displayName: entry.displayName,
            bodyParts: entry.bodyParts,
            equipmentType: entry.equipmentType,
            source: .standard,
            beginnerFriendly: entry.beginnerFriendly,
            isAvailable: isAvailable,
            catalogEntry: entry
        )
    }

    /// Standard equipment from a saved `GymMachine` selection.
    ///
    /// When the catalog no longer contains the saved `machineId` (an id
    /// retired in a later app version), the saved `displayName` snapshot
    /// is used so the user's選択 never turns into a blank row. Such an
    /// entry simply carries no catalog metadata.
    init(machine: GymMachine) {
        if let entry = MachineCatalog.entry(for: machine.machineId) {
            self.init(entry: entry, isAvailable: machine.isAvailable)
        } else {
            self.init(
                id: machine.machineId,
                displayName: machine.displayName,
                bodyParts: [],
                equipmentType: nil,
                source: .standard,
                beginnerFriendly: nil,
                isAvailable: machine.isAvailable,
                catalogEntry: nil
            )
        }
    }

    /// Custom equipment authored by the user. Unknown persisted raw
    /// values (body parts, equipment type) are dropped by the model's
    /// `resolved*` accessors rather than crashing.
    init(custom: CustomMachine) {
        self.init(
            id: custom.referenceId,
            displayName: custom.displayName,
            bodyParts: Set(custom.resolvedBodyParts),
            equipmentType: custom.resolvedEquipmentType,
            source: .custom,
            // The user does not grade their own equipment, so difficulty
            // is genuinely unknown — not "false", not "true".
            beginnerFriendly: nil,
            isAvailable: custom.isAvailable,
            catalogEntry: nil,
            customMachineId: custom.id
        )
    }

    /// Every bundled catalog machine as standard equipment. Used only for
    /// generic planning when no gym is configured; gym-aware generation
    /// must use `GymRepository.availableEquipment(for:availableOnly:)`.
    static func standardCatalog(_ catalog: [MachineCatalogEntry] = MachineCatalog.all) -> [AvailableEquipment] {
        catalog.map { AvailableEquipment(entry: $0) }
    }
}

// MARK: - Query matching

extension AvailableEquipment {
    /// Whether this item satisfies `query`.
    ///
    /// Standard equipment delegates to the existing
    /// `MachineCatalogEntry.matches(_:)` so catalog search semantics
    /// (id + tags + secondary muscles + metadata filters) are unchanged.
    /// Custom equipment has no catalog metadata, so it matches on the
    /// fields it actually has: display name and body parts. A query that
    /// filters on catalog-only metadata therefore excludes custom items,
    /// which is the honest result — we do not invent metadata for them.
    func matches(_ query: MachineCatalogQuery) -> Bool {
        if let catalogEntry { return catalogEntry.matches(query) }
        if query.isEmpty { return true }

        let trimmedSearch = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            guard displayName.lowercased().contains(trimmedSearch.lowercased()) else { return false }
        }
        if !query.bodyParts.isEmpty {
            guard query.bodyParts.contains(where: { bodyParts.contains($0) }) else { return false }
        }
        if let wanted = query.equipmentType {
            guard equipmentType == wanted else { return false }
        }
        // Catalog-only dimensions: a custom machine carries none of these,
        // so any such filter excludes it rather than guessing.
        if query.category != nil { return false }
        if query.movementPattern != nil { return false }
        if query.difficulty != nil { return false }
        if query.beginnerFriendlyOnly {
            guard beginnerFriendly == true else { return false }
        }
        if query.tags.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return false
        }
        return true
    }
}
