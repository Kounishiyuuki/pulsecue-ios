//
//  AccountLocalDataAdoption.swift
//  Pulse Cue
//
//  "この端末の記録をこのアカウントに引き継ぐ" as one transaction across the
//  workout and health stores.
//
//  The order is the whole point:
//
//    1. workout preflight   ─┐ every fetch, tombstone check and conflict
//    2. health preflight    ─┘ decision; no writes
//    3. workout apply       ─┐ assignments, inserts and deletes only;
//    4. health apply        ─┘ nothing here can throw
//    5. one save
//    6. on failure: health undo, then workout undo
//
//  Running one domain's whole adoption and then the other's — even inside a
//  single save — lets the second domain's preflight throw with the first
//  already applied, and a context carrying half an adoption is committed by
//  the next unrelated save anywhere in the app. Here both plans exist before
//  either touches a row.
//
//  The business logic stays in `AccountScopedSyncStore` and
//  `HealthDataAdoptionStore`; this type only orders their phases.
//
//  Undo is per row, never `rollback()`, which would discard unrelated unsaved
//  work in the shared context.
//
//  Out of scope on purpose: favorite meals and manual health targets. They
//  are per-scope UserDefaults settings, not records, and cannot share a
//  SwiftData transaction; guest's stay guest's.
//

import Foundation
import SwiftData

struct AccountLocalDataAdoptionStore {

    struct Summary: Equatable {
        var workout: AccountScopedSyncStore.GuestAdoptionSummary = .nothing
        var health: HealthDataAdoptionStore.Summary = .nothing
    }

    /// Production saves; tests substitute a commit that inspects the context
    /// or fails.
    private let commit: (ModelContext) throws -> Void

    init() {
        self.commit = { try $0.save() }
    }

    init(commit: @escaping (ModelContext) throws -> Void) {
        self.commit = commit
    }

    /// Adopts the domains the person was asked about into `accountID`, or
    /// nothing at all.
    ///
    /// `health` covers day logs, meals and the guest profile. Saves exactly
    /// once when any domain is included.
    @discardableResult
    func adoptGuestData(
        workout: Bool,
        health: Bool,
        for accountID: UUID,
        in context: ModelContext,
        now: Date = Date()
    ) throws -> Summary {
        guard workout || health else { return Summary() }
        let workoutStore = AccountScopedSyncStore()
        let healthStore = HealthDataAdoptionStore()

        let workoutPlan = workout ? try workoutStore.preflightAdoption(for: accountID, in: context) : nil
        let healthPlan = health ? try healthStore.preflight(for: accountID, in: context) : nil

        let workoutApplied = workoutPlan.map { workoutStore.applyAdoption($0, for: accountID, in: context, now: now) }
        let healthApplied = healthPlan.map { healthStore.apply($0, for: accountID, in: context) }

        do {
            try commit(context)
        } catch {
            healthApplied?.undo(in: context)
            workoutApplied?.undo(in: context)
            throw error
        }
        return Summary(
            workout: workoutPlan?.summary ?? .nothing,
            health: healthPlan?.summary ?? .nothing
        )
    }
}
