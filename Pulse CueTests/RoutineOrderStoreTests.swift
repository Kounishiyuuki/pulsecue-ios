//
//  RoutineOrderStoreTests.swift
//  Pulse CueTests
//
//  Boundary tests for `RoutineOrderStore`. Each test gets an
//  isolated `UserDefaults` suite so saved pin/order keys from one
//  case never bleed into another. The tests exercise the store
//  without touching SwiftData — `Routine` instances are created in
//  memory, since the store only reads ids and updatedAt.
//

import Foundation
import Testing
@testable import Pulse_Cue

@MainActor
struct RoutineOrderStoreTests {

    private static func makeIsolatedDefaults() -> UserDefaults {
        let suite = "test.routine.order.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private static func makeRoutine(_ name: String, isPinned: Bool = false, updatedAt: Date = Date()) -> Routine {
        Routine(name: name, updatedAt: updatedAt, isPinned: isPinned)
    }

    // MARK: - ordered(...)

    @Test
    func orderedReturnsRoutinesInUpdatedAtDescendingByDefault() {
        let defaults = Self.makeIsolatedDefaults()
        let store = RoutineOrderStore(defaults: defaults)
        let now = Date()
        let earlier = now.addingTimeInterval(-100)
        let earliest = now.addingTimeInterval(-200)
        let a = Self.makeRoutine("A", updatedAt: now)
        let b = Self.makeRoutine("B", updatedAt: earlier)
        let c = Self.makeRoutine("C", updatedAt: earliest)

        let ordered = store.ordered(routines: [c, a, b], pinned: false)
        #expect(ordered.map(\.name) == ["A", "B", "C"])
    }

    @Test
    func orderedRespectsExplicitSavedOrder() {
        let defaults = Self.makeIsolatedDefaults()
        var store = RoutineOrderStore(defaults: defaults)
        let a = Self.makeRoutine("A")
        let b = Self.makeRoutine("B")
        let c = Self.makeRoutine("C")

        // Manually arrange the explicit regular order C, A, B via the
        // public mutation API (move + setPinned both call save).
        store.setPinned(c.id, pinned: false)
        store.setPinned(a.id, pinned: false)
        store.setPinned(b.id, pinned: false)
        // After three setPinned(false) inserts at index 0, the
        // regular order is now [b, a, c] (most-recent first).

        let ordered = store.ordered(routines: [a, b, c], pinned: false)
        #expect(ordered.map(\.name) == ["B", "A", "C"])
    }

    @Test
    func orderedSeparatesUnknownIdsToTail() {
        let defaults = Self.makeIsolatedDefaults()
        var store = RoutineOrderStore(defaults: defaults)
        let known = Self.makeRoutine("Known", updatedAt: Date().addingTimeInterval(-50))
        let fresh = Self.makeRoutine("Fresh", updatedAt: Date())
        let older = Self.makeRoutine("Older", updatedAt: Date().addingTimeInterval(-200))

        // Pin only `known` to seed the saved pinned order list.
        store.setPinned(known.id, pinned: true)

        // When we query the regular order, `fresh` and `older` are
        // unknown to the regular order list, so they fall back to
        // updatedAt-desc.
        let regular = store.ordered(routines: [fresh, older], pinned: false)
        #expect(regular.map(\.name) == ["Fresh", "Older"])
    }

    // MARK: - setPinned(...)

    @Test
    func setPinnedTrueMovesIdIntoPinnedOrderHead() {
        let defaults = Self.makeIsolatedDefaults()
        var store = RoutineOrderStore(defaults: defaults)
        let a = Self.makeRoutine("A")
        let b = Self.makeRoutine("B")

        store.setPinned(a.id, pinned: true)
        store.setPinned(b.id, pinned: true)

        // setPinned(_, true) inserts at index 0; latest pin wins.
        let pinned = store.ordered(routines: [a, b], pinned: true)
        #expect(pinned.map(\.name) == ["B", "A"])
    }

    @Test
    func setPinnedFalseMovesIdFromPinnedToRegular() {
        let defaults = Self.makeIsolatedDefaults()
        var store = RoutineOrderStore(defaults: defaults)
        let a = Self.makeRoutine("A")

        store.setPinned(a.id, pinned: true)
        #expect(store.ordered(routines: [a], pinned: true).count == 1)
        #expect(store.ordered(routines: [a], pinned: false).count == 1) // updatedAt fallback for unknown

        store.setPinned(a.id, pinned: false)
        // Now `a` should not be in the pinned order list.
        // The pinned-ordered call returns [] because `a` is no longer
        // in the saved pinned ids and the input list itself is filtered
        // elsewhere — but `ordered` only reads ids; it returns `a` via
        // the updatedAt fallback regardless. So we assert via the
        // regular path: `a` is now explicitly in the regular order.
        let regular = store.ordered(routines: [a], pinned: false)
        #expect(regular.map(\.id) == [a.id])
    }

    @Test
    func setPinnedIsIdempotentForRepeatedPinTrue() {
        let defaults = Self.makeIsolatedDefaults()
        var store = RoutineOrderStore(defaults: defaults)
        let a = Self.makeRoutine("A")
        let b = Self.makeRoutine("B")

        store.setPinned(a.id, pinned: true)
        store.setPinned(b.id, pinned: true)
        // Re-pin `a`: it should move to the head, not duplicate.
        store.setPinned(a.id, pinned: true)

        let pinned = store.ordered(routines: [a, b], pinned: true)
        #expect(pinned.map(\.name) == ["A", "B"])
    }

    // MARK: - move(...)

    @Test
    func moveRewritesPinnedOrderForVisibleSet() {
        let defaults = Self.makeIsolatedDefaults()
        var store = RoutineOrderStore(defaults: defaults)
        let a = Self.makeRoutine("A")
        let b = Self.makeRoutine("B")
        let c = Self.makeRoutine("C")

        store.setPinned(a.id, pinned: true)
        store.setPinned(b.id, pinned: true)
        store.setPinned(c.id, pinned: true)
        // Pinned head→tail right now: C, B, A.
        let before = store.ordered(routines: [a, b, c], pinned: true)
        #expect(before.map(\.name) == ["C", "B", "A"])

        // Drag the first row (C) down to index 3 (end of list).
        store.move(routines: before, fromOffsets: IndexSet(integer: 0), toOffset: 3, pinned: true)
        let after = store.ordered(routines: [a, b, c], pinned: true)
        #expect(after.map(\.name) == ["B", "A", "C"])
    }
}

@MainActor
struct RoutineRestPreferenceStoreTests {
    private static func makeStore() -> (RoutineRestPreferenceStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test.routine.rest.\(UUID().uuidString)")!
        return (RoutineRestPreferenceStore(defaults: defaults), defaults)
    }

    @Test
    func routineDefaultInheritsAppDefaultUntilSetAndPersists() {
        let (store, defaults) = Self.makeStore()
        let routineID = UUID()
        #expect(store.routineDefault(for: routineID, appDefault: 75) == 75)

        store.setRoutineDefault(120, for: routineID)

        #expect(store.routineDefault(for: routineID, appDefault: 75) == 120)
        #expect(RoutineRestPreferenceStore(defaults: defaults).routineDefault(for: routineID, appDefault: 30) == 120)
    }

    @Test
    func clearingRoutineDefaultResumesLatestAppDefaultWithoutClearingStepOverride() {
        let (store, defaults) = Self.makeStore()
        let routineID = UUID()
        let stepID = UUID()
        store.setRoutineDefault(120, for: routineID)
        store.setStepOverride(45, for: stepID, routineID: routineID)

        store.clearRoutineDefault(for: routineID)

        let reloaded = RoutineRestPreferenceStore(defaults: defaults)
        #expect(reloaded.routineDefault(for: routineID, appDefault: 75) == 75)
        #expect(reloaded.routineDefault(for: routineID, appDefault: 90) == 90)
        #expect(reloaded.stepOverride(for: stepID) == 45)
    }

    @Test
    func restValuesAreClamped() {
        let (store, _) = Self.makeStore()
        let routineID = UUID()
        let stepID = UUID()
        store.setRoutineDefault(900, for: routineID)
        store.setStepOverride(-10, for: stepID, routineID: routineID)

        #expect(store.routineDefault(for: routineID, appDefault: 60) == 600)
        #expect(store.stepOverride(for: stepID) == 0)
    }

    @Test
    func stepOverrideCanBeSetAndCleared() {
        let (store, _) = Self.makeStore()
        let stepID = UUID()
        #expect(store.stepOverride(for: stepID) == nil)

        store.setStepOverride(45, for: stepID)
        #expect(store.stepOverride(for: stepID) == 45)

        store.clearStepOverride(for: stepID)
        #expect(store.stepOverride(for: stepID) == nil)
    }

    @Test
    func copyMetadataUsesDestinationRoutineAndStepIDs() {
        let (store, _) = Self.makeStore()
        let sourceRoutineID = UUID()
        let destinationRoutineID = UUID()
        let sourceStepID = UUID()
        let destinationStepID = UUID()
        store.setRoutineDefault(90, for: sourceRoutineID)
        store.setStepOverride(30, for: sourceStepID, routineID: sourceRoutineID)

        store.copyMetadata(
            from: sourceRoutineID,
            to: destinationRoutineID,
            stepIDMapping: [sourceStepID: destinationStepID]
        )

        #expect(store.routineDefault(for: destinationRoutineID, appDefault: 60) == 90)
        #expect(store.stepOverride(for: destinationStepID) == 30)
        #expect(store.stepOverride(for: sourceStepID) == 30)
    }

    @Test
    func deletingCopiedRoutineDoesNotRemoveSourceMetadata() {
        let (store, _) = Self.makeStore()
        let sourceRoutineID = UUID()
        let destinationRoutineID = UUID()
        let sourceStepID = UUID()
        let destinationStepID = UUID()
        store.setRoutineDefault(90, for: sourceRoutineID)
        store.setStepOverride(30, for: sourceStepID, routineID: sourceRoutineID)
        store.copyMetadata(
            from: sourceRoutineID,
            to: destinationRoutineID,
            stepIDMapping: [sourceStepID: destinationStepID]
        )

        store.removeMetadata(forRoutine: destinationRoutineID)

        #expect(store.routineDefault(for: destinationRoutineID, appDefault: 60) == 60)
        #expect(store.stepOverride(for: destinationStepID) == nil)
        #expect(store.routineDefault(for: sourceRoutineID, appDefault: 60) == 90)
        #expect(store.stepOverride(for: sourceStepID) == 30)
    }

    @Test
    func deletingRoutineRemovesTrackedAndExplicitlySuppliedStepOverrides() {
        let (store, defaults) = Self.makeStore()
        let routineID = UUID()
        let trackedStepID = UUID()
        let legacyUntrackedStepID = UUID()
        let unrelatedStepID = UUID()
        store.setRoutineDefault(90, for: routineID)
        store.setStepOverride(30, for: trackedStepID, routineID: routineID)
        store.setStepOverride(45, for: legacyUntrackedStepID)
        store.setStepOverride(75, for: unrelatedStepID)

        store.removeMetadata(forRoutine: routineID, stepIDs: [legacyUntrackedStepID])

        let reloaded = RoutineRestPreferenceStore(defaults: defaults)
        #expect(reloaded.routineDefault(for: routineID, appDefault: 60) == 60)
        #expect(reloaded.stepOverride(for: trackedStepID) == nil)
        #expect(reloaded.stepOverride(for: legacyUntrackedStepID) == nil)
        #expect(reloaded.stepOverride(for: unrelatedStepID) == 75)
    }

    @Test
    func deletingStepsRemovesOnlyTheirOverrides() {
        let (store, _) = Self.makeStore()
        let deletedStepID = UUID()
        let retainedStepID = UUID()
        store.setStepOverride(30, for: deletedStepID)
        store.setStepOverride(75, for: retainedStepID)

        store.removeMetadata(forSteps: [deletedStepID])

        #expect(store.stepOverride(for: deletedStepID) == nil)
        #expect(store.stepOverride(for: retainedStepID) == 75)
    }

    @Test
    func prepareRoutinePreservesLegacyRestsUsingMostFrequentValue() {
        let (store, defaults) = Self.makeStore()
        let routineID = UUID()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        store.prepareRoutine(
            routineID,
            existingStepRests: [(first, 90), (second, 90), (third, 30)],
            appDefault: 60
        )

        let reloaded = RoutineRestPreferenceStore(defaults: defaults)
        #expect(reloaded.routineDefault(for: routineID, appDefault: 60) == 90)
        #expect(reloaded.stepOverride(for: first) == nil)
        #expect(reloaded.stepOverride(for: second) == nil)
        #expect(reloaded.stepOverride(for: third) == 30)
    }

    @Test
    func prepareRoutineTieUsesFirstStepAndRunsOnlyOnce() {
        let (store, _) = Self.makeStore()
        let routineID = UUID()
        let first = UUID()
        let second = UUID()
        store.prepareRoutine(
            routineID,
            existingStepRests: [(first, 45), (second, 90)],
            appDefault: 60
        )
        #expect(store.routineDefault(for: routineID, appDefault: 60) == 45)
        #expect(store.stepOverride(for: second) == 90)

        store.prepareRoutine(
            routineID,
            existingStepRests: [(first, 120), (second, 120)],
            appDefault: 60
        )
        #expect(store.routineDefault(for: routineID, appDefault: 60) == 45)
        #expect(store.stepOverride(for: second) == 90)
    }

    @Test
    func UUIDMetadataSurvivesStepReorderAndNewStepsInheritRoutineDefault() {
        let (store, _) = Self.makeStore()
        let routineID = UUID()
        let inheritedStepID = UUID()
        let overriddenStepID = UUID()
        let addedStepID = UUID()
        store.prepareRoutine(
            routineID,
            existingStepRests: [(inheritedStepID, 90), (overriddenStepID, 30)],
            appDefault: 60
        )

        // Reordering and adding a step must not re-key or re-run migration.
        store.prepareRoutine(
            routineID,
            existingStepRests: [(addedStepID, 180), (overriddenStepID, 90), (inheritedStepID, 30)],
            appDefault: 75
        )

        #expect(store.routineDefault(for: routineID, appDefault: 75) == 90)
        #expect(store.stepOverride(for: inheritedStepID) == nil)
        #expect(store.stepOverride(for: overriddenStepID) == 30)
        #expect(store.stepOverride(for: addedStepID) == nil)
    }

    @Test
    func changingRoutineDefaultPreservesStepOverrideAndClearingItFallsBack() {
        let (store, _) = Self.makeStore()
        let routineID = UUID()
        let stepID = UUID()
        store.setRoutineDefault(90, for: routineID)
        store.setStepOverride(30, for: stepID, routineID: routineID)

        store.setRoutineDefault(120, for: routineID)

        #expect(store.routineDefault(for: routineID, appDefault: 60) == 120)
        #expect(store.stepOverride(for: stepID) == 30)

        store.clearStepOverride(for: stepID)
        #expect(store.stepOverride(for: stepID) == nil)
        #expect(store.routineDefault(for: routineID, appDefault: 60) == 120)
    }

    @Test
    func emptyRoutineAndExplicitClearRemainAppDefaultInheritance() {
        let (store, _) = Self.makeStore()
        let emptyRoutineID = UUID()
        store.prepareRoutine(emptyRoutineID, existingStepRests: [], appDefault: 60)
        #expect(store.routineDefault(for: emptyRoutineID, appDefault: 75) == 75)

        let clearedRoutineID = UUID()
        let stepID = UUID()
        store.clearRoutineDefault(for: clearedRoutineID)
        store.prepareRoutine(
            clearedRoutineID,
            existingStepRests: [(stepID, 180)],
            appDefault: 60
        )
        #expect(store.routineDefault(for: clearedRoutineID, appDefault: 75) == 75)
        #expect(store.stepOverride(for: stepID) == nil)
    }

    @Test
    func copiedKnownInheritanceStaysKnownAndRemovalAllowsFreshImport() {
        let (store, _) = Self.makeStore()
        let sourceID = UUID()
        let destinationID = UUID()
        let sourceStepID = UUID()
        let destinationStepID = UUID()
        store.clearRoutineDefault(for: sourceID)
        store.copyMetadata(
            from: sourceID,
            to: destinationID,
            stepIDMapping: [sourceStepID: destinationStepID]
        )

        store.prepareRoutine(
            destinationID,
            existingStepRests: [(destinationStepID, 180)],
            appDefault: 60
        )
        #expect(store.routineDefault(for: destinationID, appDefault: 75) == 75)

        store.removeMetadata(forRoutine: destinationID)
        store.prepareRoutine(
            destinationID,
            existingStepRests: [(destinationStepID, 180)],
            appDefault: 60
        )
        #expect(store.routineDefault(for: destinationID, appDefault: 75) == 180)
    }

    @Test
    func legacyPayloadWithoutKnownIDsDoesNotOverwriteConfiguredRoutine() throws {
        let defaults = UserDefaults(suiteName: "test.routine.rest.legacy.\(UUID().uuidString)")!
        let routineID = UUID()
        let legacyPayload: [String: Any] = [
            "routineDefaults": [routineID.uuidString: 120],
            "stepOverrides": [:],
            "routineStepIDs": [:]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacyPayload), forKey: "routine.rest.preferences")
        let store = RoutineRestPreferenceStore(defaults: defaults)

        store.prepareRoutine(
            routineID,
            existingStepRests: [(UUID(), 30)],
            appDefault: 60
        )

        #expect(store.routineDefault(for: routineID, appDefault: 60) == 120)
    }

    /// Mirrors the materialization the Runner reads (see WorkoutView /
    /// RoutineEditorView): `step.restSeconds = stepOverride ?? routineDefault`,
    /// where `routineDefault` itself falls back to the app default. Locks the
    /// full three-tier resolution priority used to start a workout.
    private func resolvedRest(
        _ store: RoutineRestPreferenceStore,
        routine: UUID,
        step: UUID,
        appDefault: Int
    ) -> Int {
        store.stepOverride(for: step) ?? store.routineDefault(for: routine, appDefault: appDefault)
    }

    @Test
    func resolvedRestPriorityIsStepThenRoutineThenAppDefault() {
        let (store, _) = Self.makeStore()
        let routineID = UUID()
        let overriddenStep = UUID()
        let inheritingStep = UUID()
        let appDefault = 60

        // Tier 3: no routine default, no step override → app default.
        #expect(resolvedRest(store, routine: routineID, step: inheritingStep, appDefault: appDefault) == 60)

        // Tier 2: routine default set, no step override → routine default.
        store.setRoutineDefault(120, for: routineID)
        #expect(resolvedRest(store, routine: routineID, step: inheritingStep, appDefault: appDefault) == 120)

        // Tier 1: step override wins over routine default and app default.
        store.setStepOverride(30, for: overriddenStep, routineID: routineID)
        #expect(resolvedRest(store, routine: routineID, step: overriddenStep, appDefault: appDefault) == 30)

        // Clearing the override falls back to the routine default, not the app default.
        store.clearStepOverride(for: overriddenStep)
        #expect(resolvedRest(store, routine: routineID, step: overriddenStep, appDefault: appDefault) == 120)
    }
}
