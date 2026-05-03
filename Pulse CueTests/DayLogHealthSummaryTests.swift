//
//  DayLogHealthSummaryTests.swift
//  Pulse CueTests
//
//  Unit tests for DayLog / DayLogStore (one record per local date) and
//  the pure HealthSummary computations (weekly averages, weight moving
//  average, weight trend, filled-day count, edge cases).
//
//  These tests use an in-memory SwiftData ModelContainer; no networking,
//  HealthKit, or UserDefaults state is involved.
//

import Foundation
import SwiftData
import Testing
@testable import Pulse_Cue

// MARK: - DayLog / DayLogStore

@MainActor
struct DayLogStoreTests {

    private static func makeContext() throws -> ModelContext {
        let schema = Schema([
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            DayLog.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    @Test
    func fetchOrCreateTodayNormalizesToStartOfDay() throws {
        let context = try Self.makeContext()
        let now = Date()
        let log = DayLogStore.fetchOrCreateToday(modelContext: context, now: now)
        #expect(log.date == DateUtils.startOfDay(now))
    }

    @Test
    func fetchOrCreateIsIdempotentForSameLocalDate() throws {
        let context = try Self.makeContext()
        let morning = makeDate(year: 2026, month: 5, day: 3, hour: 7)
        let evening = makeDate(year: 2026, month: 5, day: 3, hour: 22)

        let first = DayLogStore.fetchOrCreate(date: morning, modelContext: context)
        let second = DayLogStore.fetchOrCreate(date: evening, modelContext: context)

        // Same instance returned for the same local date despite different times.
        #expect(first === second)
        // Date is normalized to startOfDay.
        #expect(first.date == DateUtils.startOfDay(morning))

        // Only one record exists.
        let all = try context.fetch(FetchDescriptor<DayLog>())
        #expect(all.count == 1)
    }

    @Test
    func fetchOrCreateMakesDistinctRecordsForDifferentLocalDates() throws {
        let context = try Self.makeContext()
        let day1 = makeDate(year: 2026, month: 5, day: 1)
        let day2 = makeDate(year: 2026, month: 5, day: 2)

        let log1 = DayLogStore.fetchOrCreate(date: day1, modelContext: context)
        let log2 = DayLogStore.fetchOrCreate(date: day2, modelContext: context)

        #expect(log1.date != log2.date)
        let all = try context.fetch(FetchDescriptor<DayLog>())
        #expect(all.count == 2)
    }

    @Test
    func fetchReturnsNilWhenAbsent() throws {
        let context = try Self.makeContext()
        let day = makeDate(year: 2026, month: 5, day: 3)
        #expect(DayLogStore.fetch(date: day, modelContext: context) == nil)
    }

    @Test
    func fetchReturnsExistingRecord() throws {
        let context = try Self.makeContext()
        let day = makeDate(year: 2026, month: 5, day: 3)
        let created = DayLogStore.fetchOrCreate(date: day, modelContext: context)
        let found = DayLogStore.fetch(date: day, modelContext: context)
        #expect(found === created)
    }

    @Test
    func recentReturnsLogsInsideTheWindow() throws {
        let context = try Self.makeContext()
        let now = makeDate(year: 2026, month: 5, day: 10)
        // Window with days: 7 → covers offsets [-6 ... 0] inclusive.
        for offset in [0, -1, -3, -6, -7, -15] {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: now)!
            _ = DayLogStore.fetchOrCreate(date: date, modelContext: context)
        }

        let recent = DayLogStore.recent(days: 7, ending: now, modelContext: context)
        // -7 and -15 are outside; the rest are inside.
        #expect(recent.count == 4)
        // Sorted descending — first element is today (offset 0).
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        #expect(recent.first?.date == today)
    }
}

// MARK: - HealthSummary

@MainActor
struct HealthSummaryTests {

    private struct Entry {
        let offsetDays: Int
        var intake: Int? = nil
        var exercise: Int? = nil
        var sleep: Int? = nil
        var weight: Double? = nil
    }

    /// Build an in-memory ModelContext + an array of DayLogs sorted
    /// most-recent-first, matching the contract HealthSummary expects.
    private static func makeLogs(now: Date, _ entries: [Entry]) throws -> [DayLog] {
        let schema = Schema([
            Routine.self,
            Step.self,
            Session.self,
            StepResult.self,
            DayLog.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var logs: [DayLog] = []
        for entry in entries {
            let date = cal.date(byAdding: .day, value: entry.offsetDays, to: today)!
            let log = DayLog(
                date: date,
                intakeCalories: entry.intake,
                exerciseCalories: entry.exercise,
                sleepMinutes: entry.sleep,
                weightKg: entry.weight
            )
            context.insert(log)
            logs.append(log)
        }
        logs.sort { $0.date > $1.date }
        return logs
    }

    // MARK: today values

    @Test
    func todayBalanceIsIntakeMinusExercise() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 2000, exercise: 300)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.todayBalance == 1700)
    }

    @Test
    func todayBalanceIsNilWhenIntakeAndExerciseAreBothNil() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, sleep: 480, weight: 70.0)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.todayBalance == nil)
    }

    @Test
    func todayBalanceTreatsMissingExerciseAsZero() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 1800)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.todayBalance == 1800)
    }

    @Test
    func todayBalanceIsNilWhenTodaysLogIsMissing() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: -1, intake: 2000, exercise: 300)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.todayBalance == nil)
        #expect(summary.todayLog == nil)
    }

    @Test
    func todayValueAccessorsReadFromTodaysLog() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 2200, exercise: 250, sleep: 460, weight: 71.4)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.todayIntake == 2200)
        #expect(summary.todayExercise == 250)
        #expect(summary.todaySleepMinutes == 460)
        #expect(summary.todayWeight == 71.4)
    }

    // MARK: weekly averages

    @Test
    func weeklyBalanceAverageRequiresMinCountDays() throws {
        let now = Date()
        // Only 2 days with calorie data — below default minCount = 3.
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 2000, exercise: 300),
            Entry(offsetDays: -1, intake: 2200, exercise: 400)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.weeklyBalanceAverage == nil)
    }

    @Test
    func weeklyBalanceAverageIsMeanOfDailyBalances() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 2000, exercise: 300),   // 1700
            Entry(offsetDays: -1, intake: 1800, exercise: 200),  // 1600
            Entry(offsetDays: -2, intake: 2100, exercise: 100)   // 2000
        ])
        let summary = HealthSummary(logs: logs, now: now)
        // (1700 + 1600 + 2000) / 3 = 1766
        #expect(summary.weeklyBalanceAverage == 1766)
    }

    @Test
    func weeklyBalanceAverageSkipsDaysWithNoCalorieData() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 2000, exercise: 300),         // 1700
            Entry(offsetDays: -1, sleep: 480, weight: 70.0),           // skipped
            Entry(offsetDays: -2, intake: 1800, exercise: 200),        // 1600
            Entry(offsetDays: -3, intake: 2100, exercise: 100)         // 2000
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.weeklyBalanceAverage == 1766)
    }

    @Test
    func weeklyIntakeAverageIgnoresMissingValues() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 2000),
            Entry(offsetDays: -1),                  // intake nil
            Entry(offsetDays: -2, intake: 1800),
            Entry(offsetDays: -3, intake: 2200)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        // (2000 + 1800 + 2200) / 3 = 2000
        #expect(summary.weeklyIntakeAverage == 2000)
    }

    @Test
    func weeklyAveragesIgnoreLogsOutsideTheWindow() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 2000, exercise: 300),
            Entry(offsetDays: -3, intake: 1800, exercise: 200),
            Entry(offsetDays: -6, intake: 2100, exercise: 100),
            // Outside the 7-day window — must be ignored.
            Entry(offsetDays: -10, intake: 9999, exercise: 9999)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        // Ignored: (-10 day). Counted: 1700, 1600, 2000 → 1766.
        #expect(summary.weeklyBalanceAverage == 1766)
    }

    // MARK: weight

    @Test
    func weightMovingAverageRequiresMinCountWeighedDays() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, weight: 70.0),
            Entry(offsetDays: -1, weight: 70.5)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.weightMovingAverage == nil)
    }

    @Test
    func weightMovingAverageIsTheMeanOfWindowedWeights() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, weight: 70.0),
            Entry(offsetDays: -1, weight: 70.4),
            Entry(offsetDays: -2, weight: 70.8)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        let expected = (70.0 + 70.4 + 70.8) / 3.0
        let actual = try #require(summary.weightMovingAverage)
        #expect(abs(actual - expected) < 0.001)
    }

    @Test
    func weightTrendDetectsRising() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, weight: 71.5),
            Entry(offsetDays: -1, weight: 71.3),
            Entry(offsetDays: -2, weight: 70.5),
            Entry(offsetDays: -3, weight: 70.3)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.weightTrend == .rising)
    }

    @Test
    func weightTrendDetectsFalling() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, weight: 70.0),
            Entry(offsetDays: -1, weight: 70.2),
            Entry(offsetDays: -2, weight: 71.0),
            Entry(offsetDays: -3, weight: 71.3)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.weightTrend == .falling)
    }

    @Test
    func weightTrendDetectsFlatWithinThreshold() throws {
        let now = Date()
        // Newer half avg ≈ older half avg (delta < 0.2 kg).
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, weight: 70.0),
            Entry(offsetDays: -1, weight: 70.1),
            Entry(offsetDays: -2, weight: 70.0),
            Entry(offsetDays: -3, weight: 70.05)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.weightTrend == .flat)
    }

    @Test
    func weightTrendIsNilWithFewerThanFourWeights() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, weight: 70.0),
            Entry(offsetDays: -1, weight: 70.5),
            Entry(offsetDays: -2, weight: 71.0)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.weightTrend == nil)
    }

    @Test
    func latestWeightIsTheMostRecentWeighedDay() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 2000),                  // no weight today
            Entry(offsetDays: -1, weight: 71.2),
            Entry(offsetDays: -2, weight: 70.8)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.latestWeight == 71.2)
    }

    @Test
    func latestWeightCanComeFromOutsideWindow() throws {
        let now = Date()
        // The only weighed day is far outside the 7-day window —
        // latestWeight scans the entire log array.
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: -30, weight: 69.5)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.latestWeight == 69.5)
        #expect(summary.weightMovingAverage == nil) // outside window
    }

    // MARK: filled days

    @Test
    func filledDayCountCountsDaysWithAnyInput() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 2000),
            Entry(offsetDays: -1, sleep: 480),
            Entry(offsetDays: -2, weight: 70.5),
            Entry(offsetDays: -3),                    // empty — must NOT count
            Entry(offsetDays: -4, exercise: 300)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.filledDayCount == 4)
    }

    @Test
    func filledDayCountOnlyCountsLogsInsideWindow() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0, intake: 2000),       // inside
            Entry(offsetDays: -6, intake: 1800),      // inside (boundary)
            Entry(offsetDays: -7, intake: 2100),      // outside
            Entry(offsetDays: -10, intake: 1900)      // outside
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.filledDayCount == 2)
    }

    // MARK: edge cases

    @Test
    func emptyLogsDoNotCrashSummary() {
        let now = Date()
        let summary = HealthSummary(logs: [], now: now)
        #expect(summary.todayLog == nil)
        #expect(summary.todayBalance == nil)
        #expect(summary.todayIntake == nil)
        #expect(summary.todayExercise == nil)
        #expect(summary.todaySleepMinutes == nil)
        #expect(summary.todayWeight == nil)
        #expect(summary.weeklyIntakeAverage == nil)
        #expect(summary.weeklyExerciseAverage == nil)
        #expect(summary.weeklySleepAverage == nil)
        #expect(summary.weeklyBalanceAverage == nil)
        #expect(summary.weightMovingAverage == nil)
        #expect(summary.weightTrend == nil)
        #expect(summary.latestWeight == nil)
        #expect(summary.filledDayCount == 0)
    }

    @Test
    func summaryWithOnlyMissingValuesReturnsNilEverywhere() throws {
        let now = Date()
        let logs = try Self.makeLogs(now: now, [
            Entry(offsetDays: 0),
            Entry(offsetDays: -1),
            Entry(offsetDays: -2)
        ])
        let summary = HealthSummary(logs: logs, now: now)
        #expect(summary.todayBalance == nil)
        #expect(summary.weeklyIntakeAverage == nil)
        #expect(summary.weeklyExerciseAverage == nil)
        #expect(summary.weeklyBalanceAverage == nil)
        #expect(summary.weightMovingAverage == nil)
        #expect(summary.weightTrend == nil)
        #expect(summary.filledDayCount == 0)
    }
}
