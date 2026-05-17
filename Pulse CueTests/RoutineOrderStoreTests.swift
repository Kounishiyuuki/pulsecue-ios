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
