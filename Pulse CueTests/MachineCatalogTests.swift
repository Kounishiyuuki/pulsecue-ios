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

    /// The 16 machine ids the server-side import parser
    /// (`server/src/parser/machines.ts`) can emit. The iOS display catalog
    /// is the source of truth and may hold *more* ids than this, but every
    /// id the parser can produce MUST resolve to a catalog entry — an
    /// imported machine that has no catalog entry would be unusable.
    private static let serverParserIds: Set<String> = [
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

    @Test
    func serverParserIdsAreSubsetOfCatalog() {
        // The iOS catalog is allowed to add ids beyond the server parser
        // (1.0 expansion), but the parser must never reference an id the
        // catalog doesn't know — that would break gym-machine import.
        let catalogIds = Set(MachineCatalog.all.map(\.id))
        let missing = Self.serverParserIds.subtracting(catalogIds)
        #expect(missing.isEmpty, "server parser references ids missing from the iOS catalog: \(missing.sorted())")
    }

    @Test
    func catalogContainsExactlyTwentyEightEntries() {
        #expect(MachineCatalog.all.count == 28, "PulseCue 1.0 catalog must hold exactly 28 entries")
    }

    /// The original 16 published ids. These must never be renamed or
    /// removed — saved `GymMachine.machineId` rows depend on them and would
    /// orphan otherwise. A newly generated expected-set is intentionally
    /// NOT used here so an accidental rename can't slip through.
    @Test
    func originalPublishedIdsAreAllPreserved() {
        let originalIds: Set<String> = [
            "back_extension", "bench_press", "bike", "cable_machine",
            "chest_press", "dumbbells", "lat_pulldown", "leg_curl",
            "leg_extension", "leg_press", "pec_deck", "pull_up_bar",
            "seated_row", "shoulder_press", "smith_machine", "treadmill",
        ]
        let catalogIds = Set(MachineCatalog.all.map(\.id))
        let removed = originalIds.subtracting(catalogIds)
        #expect(removed.isEmpty, "original published machine ids were renamed/removed: \(removed.sorted())")
    }

    @Test
    func adHocEntryReceivesSafeDefaultsForOptionalFields() {
        // A minimal entry built through the public initializer must still
        // default every optional field to nil / empty so ad-hoc call sites
        // (tests, previews) don't have to spell them out. This guards the
        // initializer contract independently of the shipped catalog's data.
        let entry = MachineCatalogEntry(
            id: "adhoc",
            displayName: "アドホック",
            bodyParts: [.chest]
        )
        #expect(entry.category == nil)
        #expect(entry.equipmentType == nil)
        #expect(entry.movementPattern == nil)
        #expect(entry.difficulty == nil)
        #expect(entry.beginnerFriendly == nil)
        #expect(entry.secondaryMuscles.isEmpty)
        #expect(entry.setupNotes == nil)
        #expect(entry.safetyNotes == nil)
        #expect(entry.defaultSets == nil)
        #expect(entry.defaultReps == nil)
        #expect(entry.defaultRestSeconds == nil)
        #expect(entry.tags.isEmpty)
    }

    @Test
    func publishedEntriesHaveRequiredMetadata() {
        // Unlike ad-hoc entries, every SHIPPED catalog entry must carry the
        // minimal metadata the app filters and guides on. `category`,
        // `secondaryMuscles`, and default set/rep/rest remain optional by
        // design and are intentionally not required here.
        for entry in MachineCatalog.all {
            #expect(entry.equipmentType != nil, "Entry \(entry.id) is missing equipmentType")
            #expect(entry.movementPattern != nil, "Entry \(entry.id) is missing movementPattern")
            #expect(entry.difficulty != nil, "Entry \(entry.id) is missing difficulty")
            #expect(entry.beginnerFriendly != nil, "Entry \(entry.id) is missing beginnerFriendly")
            #expect(!entry.tags.isEmpty, "Entry \(entry.id) has no search tags")
        }
    }

    @Test
    func japaneseAliasTagsAreSearchable() {
        // Representative alias searches map to the intended new machines via
        // the existing display-name / id / tags search path.
        func ids(_ text: String) -> [String] {
            MachineCatalog.filteredEntries(matching: MachineCatalogQuery(searchText: text)).map(\.id)
        }
        #expect(ids("胸プレス").contains("incline_chest_press"))
        #expect(ids("胸プレス").contains("chest_press"))
        #expect(ids("懸垂補助") == ["assisted_pull_up"])
        #expect(ids("アブドミナル") == ["abdominal_machine"])
        #expect(ids("腹筋") == ["abdominal_machine"])
        #expect(ids("二頭").contains("arm_curl_machine"))
        #expect(ids("三頭").contains("triceps_extension_machine"))
        #expect(ids("お尻") == ["hip_abduction"])
        #expect(ids("臀部") == ["hip_abduction"])
        #expect(ids("ふくらはぎ") == ["calf_raise"])
        #expect(ids("リバースフライ") == ["rear_delt_fly"])
        #expect(ids("ローイングエルゴ") == ["rowing_machine"])
    }

    @Test
    func emptyAndWhitespaceSearchesStillMatchEveryEntry() {
        #expect(MachineCatalog.filteredEntries(matching: MachineCatalogQuery(searchText: "")).count == 28)
        #expect(MachineCatalog.filteredEntries(matching: MachineCatalogQuery(searchText: "   ")).count == 28)
    }

    @Test
    func newMachinesAreFilterableByExpectedBodyParts() {
        func ids(_ part: BodyPart) -> [String] {
            MachineCatalog.filteredEntries(matching: MachineCatalogQuery(bodyParts: [part])).map(\.id)
        }
        #expect(ids(.core).contains("abdominal_machine"))
        #expect(ids(.arms).contains("arm_curl_machine"))
        #expect(ids(.arms).contains("triceps_extension_machine"))
        #expect(ids(.back).contains("assisted_pull_up"))
        #expect(ids(.legs).contains("hack_squat"))
        #expect(ids(.legs).contains("hip_abduction"))
        #expect(ids(.legs).contains("calf_raise"))
        #expect(ids(.chest).contains("incline_chest_press"))
        #expect(ids(.shoulders).contains("lateral_raise_machine"))
        #expect(ids(.shoulders).contains("rear_delt_fly"))
        #expect(ids(.fullBody).contains("rowing_machine"))
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

    // MARK: - MachineCatalogQuery / filteredEntries

    @Test
    func emptyQueryReturnsEveryEntryInCatalogOrder() {
        let results = MachineCatalog.filteredEntries(matching: MachineCatalogQuery())
        #expect(results.map(\.id) == MachineCatalog.all.map(\.id))
    }

    @Test
    func whitespaceOnlyQueryStillMatchesEverything() {
        let query = MachineCatalogQuery(searchText: "   ", tags: ["  "])
        let results = MachineCatalog.filteredEntries(matching: query)
        #expect(results.count == MachineCatalog.all.count)
    }

    @Test
    func searchTextMatchesDisplayNameCaseInsensitively() {
        // "ラットプルダウン" should be findable by a substring of the
        // Japanese display name; "BENCH" should also match by id.
        let byDisplay = MachineCatalog.filteredEntries(
            matching: MachineCatalogQuery(searchText: "ラットプル")
        )
        #expect(byDisplay.map(\.id) == ["lat_pulldown"])

        let byIdUppercased = MachineCatalog.filteredEntries(
            matching: MachineCatalogQuery(searchText: "BENCH")
        )
        #expect(byIdUppercased.map(\.id) == ["bench_press"])
    }

    @Test
    func searchTextMatchesTagsCaseInsensitively() {
        // Existing catalog entries don't ship tags yet, so verify against
        // a hand-built entry through the same `matches(_:)` helper.
        let entry = MachineCatalogEntry(
            id: "test_bb",
            displayName: "Test BB",
            bodyParts: [.chest],
            tags: ["Compound", "Barbell"]
        )
        #expect(entry.matches(MachineCatalogQuery(searchText: "compound")))
        #expect(entry.matches(MachineCatalogQuery(searchText: "BAR")))
        #expect(!entry.matches(MachineCatalogQuery(searchText: "cardio")))
    }

    @Test
    func bodyPartsFilterMatchesPrimaryBodyParts() {
        let results = MachineCatalog.filteredEntries(
            matching: MachineCatalogQuery(bodyParts: [.legs])
        )
        #expect(results.allSatisfy { $0.bodyParts.contains(.legs) })
        #expect(results.contains(where: { $0.id == "leg_press" }))
        #expect(!results.contains(where: { $0.id == "pec_deck" }))
    }

    @Test
    func bodyPartsFilterAlsoMatchesSecondaryMuscles() {
        let entry = MachineCatalogEntry(
            id: "bp_secondary",
            displayName: "Secondary muscle entry",
            bodyParts: [.chest],
            secondaryMuscles: [.shoulders]
        )
        #expect(entry.matches(MachineCatalogQuery(bodyParts: [.shoulders])))
        #expect(!entry.matches(MachineCatalogQuery(bodyParts: [.legs])))
    }

    @Test
    func scalarMetadataFiltersRequireMatchingNonNilValue() {
        let populated = MachineCatalogEntry(
            id: "bp_full",
            displayName: "Full meta",
            bodyParts: [.chest],
            category: .chest,
            equipmentType: .freeWeight,
            movementPattern: .push,
            difficulty: .intermediate,
            beginnerFriendly: true
        )
        let bare = MachineCatalogEntry(
            id: "bp_bare",
            displayName: "Bare meta",
            bodyParts: [.chest]
        )

        #expect(populated.matches(MachineCatalogQuery(category: .chest)))
        #expect(!populated.matches(MachineCatalogQuery(category: .legs)))
        #expect(!bare.matches(MachineCatalogQuery(category: .chest)),
                "Entries with no category must not satisfy a category filter")

        #expect(populated.matches(MachineCatalogQuery(equipmentType: .freeWeight)))
        #expect(populated.matches(MachineCatalogQuery(movementPattern: .push)))
        #expect(populated.matches(MachineCatalogQuery(difficulty: .intermediate)))
        #expect(!populated.matches(MachineCatalogQuery(difficulty: .advanced)))
    }

    @Test
    func beginnerFriendlyOnlyFilter() {
        let yes = MachineCatalogEntry(
            id: "bf_yes", displayName: "yes", bodyParts: [.chest], beginnerFriendly: true
        )
        let no = MachineCatalogEntry(
            id: "bf_no", displayName: "no", bodyParts: [.chest], beginnerFriendly: false
        )
        let unset = MachineCatalogEntry(
            id: "bf_unset", displayName: "unset", bodyParts: [.chest]
        )

        let query = MachineCatalogQuery(beginnerFriendlyOnly: true)
        #expect(yes.matches(query))
        #expect(!no.matches(query))
        #expect(!unset.matches(query))
    }

    @Test
    func tagsFilterRequiresAllRequestedTagsCaseInsensitive() {
        let entry = MachineCatalogEntry(
            id: "tagged",
            displayName: "Tagged",
            bodyParts: [.chest],
            tags: ["Compound", "Barbell", "PushDay"]
        )
        #expect(entry.matches(MachineCatalogQuery(tags: ["compound", "BARBELL"])))
        #expect(!entry.matches(MachineCatalogQuery(tags: ["compound", "cable"])))
        // Whitespace-only tags are ignored — treated as no filter.
        #expect(entry.matches(MachineCatalogQuery(tags: ["   "])))
    }

    @Test
    func multipleFiltersCombineWithAndSemantics() {
        let entry = MachineCatalogEntry(
            id: "combo",
            displayName: "ベンチプレス カスタム",
            bodyParts: [.chest, .arms],
            category: .chest,
            equipmentType: .freeWeight,
            movementPattern: .push,
            difficulty: .intermediate,
            beginnerFriendly: true,
            tags: ["compound"]
        )

        let allMatch = MachineCatalogQuery(
            searchText: "ベンチ",
            bodyParts: [.chest],
            category: .chest,
            equipmentType: .freeWeight,
            movementPattern: .push,
            difficulty: .intermediate,
            beginnerFriendlyOnly: true,
            tags: ["compound"]
        )
        #expect(entry.matches(allMatch))

        // Flip one clause; AND semantics should reject the entry.
        var oneFails = allMatch
        oneFails.difficulty = .advanced
        #expect(!entry.matches(oneFails))
    }

    @Test
    func filteredEntriesPreservesCatalogOrder() {
        let results = MachineCatalog.filteredEntries(
            matching: MachineCatalogQuery(bodyParts: [.chest, .legs])
        )
        let expectedOrder = MachineCatalog.all
            .filter { !$0.bodyParts.isDisjoint(with: Set<BodyPart>([.chest, .legs])) }
            .map(\.id)
        #expect(results.map(\.id) == expectedOrder)
    }

    @Test
    func entryLookupReturnsKnownIds() {
        #expect(MachineCatalog.entry(for: "lat_pulldown")?.displayName == "ラットプルダウン")
        #expect(MachineCatalog.entry(for: "smith_machine")?.bodyParts.contains(.legs) == true)
        #expect(MachineCatalog.entry(for: "totally-fake-id") == nil)
    }
}
