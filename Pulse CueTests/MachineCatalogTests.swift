//
//  MachineCatalogTests.swift
//  Pulse CueTests
//
//  Sanity checks for the local machine catalog. These exist so any
//  drift between this list and the server-side catalog at
//  `server/src/parser/machines.ts` shows up in a PR diff: a renamed
//  or removed id breaks the `expectedIds` set, and any accidental
//  duplicate breaks the uniqueness check.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct MachineCatalogTests {

    @Test
    func allIdsAreUnique() {
        let ids = MachineCatalog.all.map(\.id)
        let unique = Set(ids)
        #expect(ids.count == unique.count, "Duplicate machine ids in MachineCatalog.all")
    }

    @Test
    func allIdsAreSortedAlphabetically() {
        let ids = MachineCatalog.all.map(\.id)
        #expect(ids == ids.sorted(), "MachineCatalog.all must remain sorted by id to keep PR diffs stable")
    }

    @Test
    func everyEntryHasAtLeastOneBodyPart() {
        for entry in MachineCatalog.all {
            #expect(!entry.bodyParts.isEmpty, "Entry \(entry.id) has no associated body parts")
        }
    }

    @Test
    func everyEntryHasJapaneseDisplayName() {
        for entry in MachineCatalog.all {
            #expect(!entry.displayName.isEmpty, "Entry \(entry.id) is missing a display name")
        }
    }

    @Test
    func catalogStaysInSyncWithServer() {
        // Mirrors server/src/parser/machines.ts at the time of writing.
        // When the server catalog changes, update this set in the same
        // PR — the failing diff is intentional.
        let expectedIds: Set<String> = [
            "back_extension",
            "bench_press",
            "bike",
            "cable_machine",
            "chest_press",
            "dumbbells",
            "lat_pulldown",
            "leg_curl",
            "leg_extension",
            "leg_press",
            "pec_deck",
            "pull_up_bar",
            "seated_row",
            "shoulder_press",
            "smith_machine",
            "treadmill",
        ]
        let actualIds = Set(MachineCatalog.all.map(\.id))
        #expect(actualIds == expectedIds, "iOS MachineCatalog drifted from server/src/parser/machines.ts")
    }

    @Test
    func entryLookupReturnsKnownIds() {
        #expect(MachineCatalog.entry(for: "lat_pulldown")?.displayName == "ラットプルダウン")
        #expect(MachineCatalog.entry(for: "smith_machine")?.bodyParts.contains(.legs) == true)
        #expect(MachineCatalog.entry(for: "totally-fake-id") == nil)
    }
}
