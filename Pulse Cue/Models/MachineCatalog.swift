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

struct MachineCatalogEntry: Identifiable, Hashable {
    /// Canonical id matching the server catalog (e.g. `lat_pulldown`).
    let id: String
    /// User-facing Japanese label.
    let displayName: String
    /// Body parts this machine primarily trains. Used by the plan
    /// generator to filter candidate machines.
    let bodyParts: Set<BodyPart>
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
