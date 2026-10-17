//
//  DayLogStore.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Every lookup is by (owner, day) and every creation takes its owner from the
//  scope, so no caller can read or create another owner's log. Lookups are an
//  explicit fetch on both halves rather than a blind insert that leans on
//  `scopedDayKey`'s unique constraint to upsert: which duplicate's values win
//  that upsert is SwiftData's choice, not ours, and the constraint is meant as
//  the last line of defence, not the logic.
//

import Foundation
import SwiftData

struct DayLogStore {
    static func fetchOrCreateToday(
        scope: HealthDataScope,
        modelContext: ModelContext,
        now: Date = Date()
    ) -> DayLog? {
        fetchOrCreate(date: DateUtils.startOfDay(now), scope: scope, modelContext: modelContext)
    }

    /// The scope's log for `date`, inserted if missing. Nil while the scope is
    /// undetermined: there is no owner to give a new row.
    static func fetchOrCreate(
        date: Date,
        scope: HealthDataScope,
        modelContext: ModelContext
    ) -> DayLog? {
        guard scope.canCreateHealthData else { return nil }
        let day = DateUtils.startOfDay(date)
        if let existing = fetch(date: day, scope: scope, modelContext: modelContext) {
            return existing
        }
        let log = DayLog(date: day, ownerAccountID: scope.creationOwnerAccountID)
        modelContext.insert(log)
        return log
    }

    static func fetch(date: Date, scope: HealthDataScope, modelContext: ModelContext) -> DayLog? {
        let day = DateUtils.startOfDay(date)
        let descriptor: FetchDescriptor<DayLog>
        switch scope {
        case .undetermined:
            return nil
        case .guest:
            descriptor = FetchDescriptor<DayLog>(
                predicate: #Predicate<DayLog> { $0.date == day && $0.ownerAccountID == nil }
            )
        case let .account(id):
            descriptor = FetchDescriptor<DayLog>(
                predicate: #Predicate<DayLog> { $0.date == day && $0.ownerAccountID == id }
            )
        }
        return (try? modelContext.fetch(descriptor))?.first
    }

    static func recent(
        days: Int,
        ending now: Date = Date(),
        scope: HealthDataScope,
        modelContext: ModelContext
    ) -> [DayLog] {
        let cal = Calendar.current
        let end = DateUtils.startOfDay(now)
        let start = cal.date(byAdding: .day, value: -(max(days, 1) - 1), to: end) ?? end
        let descriptor = FetchDescriptor<DayLog>(
            sortBy: [SortDescriptor(\DayLog.date, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return scope.visible(all).filter { $0.date >= start && $0.date <= end }
    }
}
