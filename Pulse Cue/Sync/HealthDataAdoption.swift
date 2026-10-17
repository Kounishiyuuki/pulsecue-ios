//
//  HealthDataAdoption.swift
//  Pulse Cue
//
//  Moving guest day logs, meals and the guest profile into an account — the
//  health half of "この端末の記録をこのアカウントに引き継ぐ".
//
//  Only nil → account. Rows another account owns are never read here, let
//  alone moved, and an owned row's `adopt(into:)` refuses anyway.
//
//  Nothing here is about the cloud. There is no health sync; adoption only
//  decides which local scope a row appears in.
//
//  ## Same-day conflicts
//
//  A day is the unit: the guest log for day X *and* the guest meals for day X
//  move together or stay together, because a log's intake is derived from its
//  day's meals and splitting them would leave one side describing meals it no
//  longer has.
//
//  For a day the account has nothing for, the guest rows simply change owner.
//  Otherwise each log field is compared:
//
//    * guest only   → copied into the account's empty field
//    * account only → kept
//    * both, equal  → kept
//    * both, differ → **conflict**
//
//  `intakeCalories` follows `NutritionLedger`'s ownership rule. If neither
//  side has meals that day it is an ordinary field. If either side does, the
//  merged day's intake is recomputed from the union of its meals — unless the
//  other side holds a quick-input intake with no meals behind it, which the
//  meals would overwrite: that is a conflict too.
//
//  A conflicting day stays entirely guest, untouched, and the account's day is
//  left exactly as it was. Nothing is overwritten and nothing is lost; the
//  guest copy is still there in guest scope. A merged guest log is deleted
//  only once all of its values are in the account's log.
//
//  ## Profile
//
//  An account that already has a profile keeps it, and the guest profile stays
//  guest. An account without one adopts the guest profile `UserProfileStore`
//  would show.
//
//  ## Atomicity
//
//  Favorite meals and manual targets are not adopted: they are per-scope
//  UserDefaults settings (`HealthScopedDefaults`), not records, and keeping
//  them out keeps this a SwiftData-only transaction.
//
//  The `AccountScopedSyncStore` shape: preflight does every fetch and decision
//  and touches nothing; apply only assigns, inserts and deletes; then one
//  commit. If the commit throws, apply's own record puts back exactly what it
//  changed — owners, keys, merged fields, inserted logs, and deleted guest
//  logs recreated with their values (a guest log has no identity beyond
//  owner, day and values) — rather
//  than `rollback()`, which would discard unrelated unsaved work.
//

import Foundation
import SwiftData

struct HealthDataAdoptionStore {

    /// What one adoption did. Conflicting days are reported, not resolved.
    struct Summary: Equatable {
        var adoptedLogs = 0
        var mergedLogs = 0
        var adoptedMeals = 0
        var adoptedProfile = false
        /// Days left in guest scope because both sides disagreed.
        var conflictingDays: [Date] = []

        static let nothing = Summary()
    }

    /// Production saves; tests substitute a failing commit. The guest-adoption
    /// prompt does not use this entry point: it goes through
    /// `AccountLocalDataAdoptionStore`, which preflights workouts and health
    /// before applying either and saves once.
    private let commit: (ModelContext) throws -> Void

    init() {
        self.commit = { try $0.save() }
    }

    init(commit: @escaping (ModelContext) throws -> Void) {
        self.commit = commit
    }

    /// Whether this device holds guest health data worth asking about.
    ///
    /// Empty day logs (Home creates today's on launch) and the profile alone
    /// do not count: on their own they are not a record anyone kept.
    func hasGuestHealthData(in context: ModelContext) throws -> Bool {
        var meals = FetchDescriptor<MealEntry>(predicate: #Predicate { $0.ownerAccountID == nil })
        meals.fetchLimit = 1
        if try !context.fetch(meals).isEmpty { return true }
        let logs = try context.fetch(FetchDescriptor<DayLog>(predicate: #Predicate { $0.ownerAccountID == nil }))
        return logs.contains { !Self.isEmpty($0) }
    }

    /// Whether adopting into `accountID` would move the guest profile: one
    /// exists and the account has none. Not a reason to ask on its own, but
    /// part of the answer once the question is asked.
    func wouldAdoptGuestProfile(into accountID: UUID, in context: ModelContext) throws -> Bool {
        var account = FetchDescriptor<UserProfile>(predicate: #Predicate { $0.ownerAccountID == accountID })
        account.fetchLimit = 1
        guard try context.fetch(account).isEmpty else { return false }
        var guest = FetchDescriptor<UserProfile>(predicate: #Predicate { $0.ownerAccountID == nil })
        guest.fetchLimit = 1
        return try !context.fetch(guest).isEmpty
    }

    @discardableResult
    func adoptGuestHealthData(for accountID: UUID, in context: ModelContext) throws -> Summary {
        let plan = try preflight(for: accountID, in: context)
        let applied = apply(plan, for: accountID, in: context)
        do {
            try commit(context)
        } catch {
            applied.undo(in: context)
            throw error
        }
        return plan.summary
    }

    // MARK: Plan

    fileprivate struct Merge {
        let target: DayLog
        let guest: DayLog
        let values: Fields
    }

    fileprivate struct Fields: Equatable {
        var intakeCalories: Int?
        var exerciseCalories: Int?
        var sleepMinutes: Int?
        var weightKg: Double?
        var note: String?

        init(_ log: DayLog?) {
            intakeCalories = log?.intakeCalories
            exerciseCalories = log?.exerciseCalories
            sleepMinutes = log?.sleepMinutes
            weightKg = log?.weightKg
            note = log?.note
        }

        func write(to log: DayLog) {
            log.intakeCalories = intakeCalories
            log.exerciseCalories = exerciseCalories
            log.sleepMinutes = sleepMinutes
            log.weightKg = weightKg
            log.note = note
        }
    }

    /// Every decision preflight made. Visible to the module so
    /// `AccountLocalDataAdoptionStore` can preflight health and workouts
    /// before either is applied; its contents stay private.
    struct Plan {
        fileprivate var adoptLogs: [DayLog] = []
        /// A guest log adopted as-is whose intake the merged meals now own.
        fileprivate var adoptLogIntakes: [(log: DayLog, intake: Int?)] = []
        fileprivate var merges: [Merge] = []
        /// Account logs that exist only to hold a recomputed intake.
        fileprivate var newLogs: [(day: Date, intake: Int)] = []
        /// Existing account logs whose intake the merged meals now own.
        fileprivate var accountIntakes: [(log: DayLog, intake: Int?)] = []
        fileprivate var adoptMeals: [MealEntry] = []
        fileprivate var adoptProfile: UserProfile?
        fileprivate var conflictingDays: [Date] = []

        var summary: Summary {
            Summary(
                adoptedLogs: adoptLogs.count,
                mergedLogs: merges.count,
                adoptedMeals: adoptMeals.count,
                adoptedProfile: adoptProfile != nil,
                conflictingDays: conflictingDays
            )
        }
    }

    /// Every fetch and every decision; no writes.
    func preflight(for accountID: UUID, in context: ModelContext) throws -> Plan {
        let guestLogs = try context.fetch(FetchDescriptor<DayLog>(predicate: #Predicate { $0.ownerAccountID == nil }))
        let accountLogs = try context.fetch(FetchDescriptor<DayLog>(predicate: #Predicate { $0.ownerAccountID == accountID }))
        let guestMeals = try context.fetch(FetchDescriptor<MealEntry>(predicate: #Predicate { $0.ownerAccountID == nil }))
        let accountMeals = try context.fetch(FetchDescriptor<MealEntry>(predicate: #Predicate { $0.ownerAccountID == accountID }))
        let guestProfiles = try context.fetch(FetchDescriptor<UserProfile>(predicate: #Predicate { $0.ownerAccountID == nil }))
        let accountProfiles = try context.fetch(FetchDescriptor<UserProfile>(predicate: #Predicate { $0.ownerAccountID == accountID }))

        let guestLogByDay = Dictionary(guestLogs.map { (DateUtils.startOfDay($0.date), $0) }, uniquingKeysWith: { a, _ in a })
        let accountLogByDay = Dictionary(accountLogs.map { (DateUtils.startOfDay($0.date), $0) }, uniquingKeysWith: { a, _ in a })
        let guestMealsByDay = Dictionary(grouping: guestMeals) { DateUtils.startOfDay($0.dayDate) }
        let accountMealsByDay = Dictionary(grouping: accountMeals) { DateUtils.startOfDay($0.dayDate) }

        var plan = Plan()
        let days = Set(guestLogByDay.keys).union(guestMealsByDay.keys).sorted()
        for day in days {
            let guestLog = guestLogByDay[day]
            let accountLog = accountLogByDay[day]
            let gMeals = guestMealsByDay[day] ?? []
            let aMeals = accountMealsByDay[day] ?? []

            guard let resolved = Self.resolve(guest: guestLog, account: accountLog, guestMeals: gMeals, accountMeals: aMeals) else {
                plan.conflictingDays.append(day)
                continue
            }
            plan.adoptMeals += gMeals
            switch (guestLog, accountLog) {
            case let (guest?, account?):
                plan.merges.append(Merge(target: account, guest: guest, values: resolved))
            case let (guest?, nil):
                plan.adoptLogs.append(guest)
                if resolved.intakeCalories != guest.intakeCalories {
                    plan.adoptLogIntakes.append((guest, resolved.intakeCalories))
                }
            case let (nil, account?):
                if resolved.intakeCalories != account.intakeCalories {
                    plan.accountIntakes.append((account, resolved.intakeCalories))
                }
            case (nil, nil):
                // Guest meals only. Same as the ledger: a row is created only
                // to hold a positive total.
                if let intake = resolved.intakeCalories {
                    plan.newLogs.append((day, intake))
                }
            }
        }

        if accountProfiles.isEmpty {
            plan.adoptProfile = UserProfileStore.select(from: guestProfiles, scope: .guest)
        }
        return plan
    }

    /// The account's day after merging, or nil when the two sides conflict.
    private static func resolve(
        guest: DayLog?,
        account: DayLog?,
        guestMeals: [MealEntry],
        accountMeals: [MealEntry]
    ) -> Fields? {
        let g = Fields(guest)
        var merged = Fields(account)

        guard let exercise = mergeField(g.exerciseCalories, merged.exerciseCalories),
              let sleep = mergeField(g.sleepMinutes, merged.sleepMinutes),
              let weight = mergeField(g.weightKg, merged.weightKg),
              let note = mergeField(g.note, merged.note)
        else { return nil }
        merged.exerciseCalories = exercise
        merged.sleepMinutes = sleep
        merged.weightKg = weight
        merged.note = note

        let meals = guestMeals + accountMeals
        if meals.isEmpty {
            guard let intake = mergeField(g.intakeCalories, merged.intakeCalories) else { return nil }
            merged.intakeCalories = intake
        } else {
            // A quick-input intake with no meals behind it would be replaced
            // by the meal total. That is the other side's value, so: conflict.
            if guestMeals.isEmpty, g.intakeCalories != nil { return nil }
            if accountMeals.isEmpty, merged.intakeCalories != nil { return nil }
            let sum = meals.filter { $0.status == .confirmed }.reduce(0) { $0 + $1.kcal }
            merged.intakeCalories = sum > 0 ? sum : nil
        }
        return merged
    }

    /// `.some(value)` to keep, nil for a conflict.
    private static func mergeField<T: Equatable>(_ guest: T?, _ account: T?) -> T?? {
        switch (guest, account) {
        case let (g?, a?): return g == a ? .some(a) : nil
        case let (g?, nil): return .some(g)
        case let (nil, a): return .some(a)
        }
    }

    private static func isEmpty(_ log: DayLog) -> Bool {
        log.intakeCalories == nil && log.exerciseCalories == nil && log.sleepMinutes == nil
            && log.weightKg == nil && (log.note ?? "").isEmpty
    }

    // MARK: Apply

    /// What apply changed, enough to put every row back.
    struct Applied {
        fileprivate var adoptedLogs: [(DayLog, HealthOwnerAdoption, intake: Int?)] = []
        fileprivate var mergedTargets: [(DayLog, Fields)] = []
        /// Deleted merged guest logs, by day and value. SwiftData does not
        /// undo a delete by re-inserting the same object, so undo recreates
        /// the row instead.
        fileprivate var deletedGuests: [(date: Date, values: Fields)] = []
        fileprivate var insertedLogs: [DayLog] = []
        fileprivate var accountIntakes: [(DayLog, Int?)] = []
        fileprivate var adoptedMeals: [(MealEntry, HealthOwnerAdoption)] = []
        fileprivate var adoptedProfile: (UserProfile, HealthOwnerAdoption)?

        func undo(in context: ModelContext) {
            for (log, adoption, intake) in adoptedLogs {
                log.undoAdoption(adoption)
                log.intakeCalories = intake
            }
            for (log, previous) in mergedTargets { previous.write(to: log) }
            for guest in deletedGuests {
                let log = DayLog(date: guest.date, ownerAccountID: nil)
                guest.values.write(to: log)
                context.insert(log)
            }
            for log in insertedLogs { context.delete(log) }
            for (log, intake) in accountIntakes { log.intakeCalories = intake }
            for (meal, adoption) in adoptedMeals { meal.undoAdoption(adoption) }
            if let (profile, adoption) = adoptedProfile { profile.undoAdoption(adoption) }
        }
    }

    /// Assignments, inserts and deletes only — nothing here can throw.
    func apply(_ plan: Plan, for accountID: UUID, in context: ModelContext) -> Applied {
        var applied = Applied()

        for log in plan.adoptLogs {
            let intake = log.intakeCalories
            if let adoption = log.adopt(into: accountID) {
                applied.adoptedLogs.append((log, adoption, intake))
            }
        }
        for (log, intake) in plan.adoptLogIntakes { log.intakeCalories = intake }
        for merge in plan.merges {
            applied.mergedTargets.append((merge.target, Fields(merge.target)))
            merge.values.write(to: merge.target)
            context.delete(merge.guest)
            applied.deletedGuests.append((merge.guest.date, Fields(merge.guest)))
        }
        for (log, intake) in plan.accountIntakes {
            applied.accountIntakes.append((log, log.intakeCalories))
            log.intakeCalories = intake
        }
        for entry in plan.newLogs {
            let log = DayLog(date: entry.day, intakeCalories: entry.intake, ownerAccountID: accountID)
            context.insert(log)
            applied.insertedLogs.append(log)
        }
        for meal in plan.adoptMeals {
            if let adoption = meal.adopt(into: accountID) {
                applied.adoptedMeals.append((meal, adoption))
            }
        }
        if let profile = plan.adoptProfile, let adoption = profile.adopt(into: accountID) {
            applied.adoptedProfile = (profile, adoption)
        }
        return applied
    }
}
