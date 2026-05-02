//
//  DayLogStore.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData

struct DayLogStore {
    static func fetchOrCreateToday(modelContext: ModelContext, now: Date = Date()) -> DayLog {
        let today = DateUtils.startOfDay(now)
        return fetchOrCreate(date: today, modelContext: modelContext)
    }

    static func fetchOrCreate(date: Date, modelContext: ModelContext) -> DayLog {
        let day = DateUtils.startOfDay(date)
        if let existing = fetch(date: day, modelContext: modelContext) {
            return existing
        }
        let log = DayLog(date: day)
        modelContext.insert(log)
        return log
    }

    static func fetch(date: Date, modelContext: ModelContext) -> DayLog? {
        let day = DateUtils.startOfDay(date)
        var descriptor = FetchDescriptor<DayLog>(
            predicate: #Predicate<DayLog> { $0.date == day }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    static func recent(days: Int, ending now: Date = Date(), modelContext: ModelContext) -> [DayLog] {
        let cal = Calendar.current
        let end = DateUtils.startOfDay(now)
        let start = cal.date(byAdding: .day, value: -(max(days, 1) - 1), to: end) ?? end
        let descriptor = FetchDescriptor<DayLog>(
            sortBy: [SortDescriptor(\DayLog.date, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.date >= start && $0.date <= end }
    }
}
