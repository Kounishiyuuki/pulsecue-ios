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
    func existingEntriesHaveSafeDefaultsForNewFields() {
        // The PR that introduced the optional metadata fields deliberately
        // did not populate them on existing entries — they should all
        // come back as nil / empty so callers can rely on safe defaults.
        for entry in MachineCatalog.all {
            #expect(entry.category == nil, "Entry \(entry.id) unexpectedly has a category set")
            #expect(entry.equipmentType == nil, "Entry \(entry.id) unexpectedly has an equipmentType set")
            #expect(entry.movementPattern == nil, "Entry \(entry.id) unexpectedly has a movementPattern set")
            #expect(entry.difficulty == nil, "Entry \(entry.id) unexpectedly has a difficulty set")
            #expect(entry.beginnerFriendly == nil)
            #expect(entry.secondaryMuscles.isEmpty)
            #expect(entry.setupNotes == nil)
            #expect(entry.safetyNotes == nil)
            #expect(entry.defaultSets == nil)
            #expect(entry.defaultReps == nil)
            #expect(entry.defaultRestSeconds == nil)
            #expect(entry.tags.isEmpty)
        }
    }

    @Test
    func entryCanCarryFullMetadata() {
        // Smoke-test that the extended init wires every field through and
        // that consumers can roundtrip the new values. We construct a
        // local entry rather than mutating the shipped catalog so this
        // test does not depend on data-population PRs that come later.
        let entry = MachineCatalogEntry(
            id: "test_bench",
            displayName: "テストベンチ",
            bodyParts: [.chest, .arms],
            category: .chest,
            equipmentType: .freeWeight,
            movementPattern: .push,
            difficulty: .intermediate,
            beginnerFriendly: false,
            secondaryMuscles: [.shoulders, .core],
            setupNotes: "ベンチを水平に",
            safetyNotes: "セーフティバーを必ず使用",
            defaultSets: 3,
            defaultReps: 8...12,
            defaultRestSeconds: 90,
            tags: ["compound", "barbell"]
        )

        #expect(entry.category == .chest)
        #expect(entry.equipmentType == .freeWeight)
        #expect(entry.movementPattern == .push)
        #expect(entry.difficulty == .intermediate)
        #expect(entry.beginnerFriendly == false)
        #expect(entry.secondaryMuscles == [.shoulders, .core])
        #expect(entry.setupNotes == "ベンチを水平に")
        #expect(entry.safetyNotes == "セーフティバーを必ず使用")
        #expect(entry.defaultSets == 3)
        #expect(entry.defaultReps == 8...12)
        #expect(entry.defaultRestSeconds == 90)
        #expect(entry.tags == ["compound", "barbell"])
    }

    @Test
    func entryLookupReturnsKnownIds() {
        #expect(MachineCatalog.entry(for: "lat_pulldown")?.displayName == "ラットプルダウン")
        #expect(MachineCatalog.entry(for: "smith_machine")?.bodyParts.contains(.legs) == true)
        #expect(MachineCatalog.entry(for: "totally-fake-id") == nil)
    }
}
