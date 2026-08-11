//
//  HealthKitInputAssistTests.swift
//  Pulse CueTests
//
//  Everything here runs against a fake client, so no HealthKit, no device and
//  no permission prompt is involved. The rules under test are the ones that
//  decide what a user sees: which sleep counts, how overlapping sources are
//  reconciled, and — most importantly — that reading a value never saves it.
//

import Foundation
import SwiftData
import Testing
#if canImport(HealthKit)
import HealthKit
#endif
@testable import Pulse_Cue

// MARK: - Fake

@MainActor
private final class FakeHealthKit: HealthKitReading {
    var isAvailable: Bool
    var authorizationResult: Bool
    var weight: Double?
    var intervals: [SleepInterval]

    private(set) var authorizationRequests = 0
    private(set) var requestedWindows: [DateInterval] = []

    init(
        isAvailable: Bool = true,
        authorizationResult: Bool = true,
        weight: Double? = nil,
        intervals: [SleepInterval] = []
    ) {
        self.isAvailable = isAvailable
        self.authorizationResult = authorizationResult
        self.weight = weight
        self.intervals = intervals
    }

    func requestReadAuthorization() async -> Bool {
        authorizationRequests += 1
        return authorizationResult
    }

    func latestBodyMassKilograms() async -> Double? { weight }

    func asleepIntervals(in window: DateInterval) async -> [SleepInterval] {
        requestedWindows.append(window)
        return intervals
    }
}

@MainActor
struct HealthKitInputAssistTests {

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private static func interval(
        _ from: (Int, Int, Int, Int, Int),
        _ to: (Int, Int, Int, Int, Int)
    ) -> SleepInterval {
        SleepInterval(
            start: date(from.0, from.1, from.2, from.3, from.4),
            end: date(to.0, to.1, to.2, to.3, to.4)
        )
    }

    // MARK: - Body mass

    @Test
    func latestWeightFillsTheInput() async {
        let fake = FakeHealthKit(weight: 72.4)
        let assist = HealthKitInputAssist(client: fake, calendar: Self.calendar)

        await assist.fetchLatestWeight()

        #expect(assist.state == .filled)
        #expect(assist.fetchedWeightKilograms == 72.4)
        #expect(fake.authorizationRequests == 1)
    }

    @Test
    func noWeightSampleReadsAsNoDataNotAsRefusal() async {
        let assist = HealthKitInputAssist(client: FakeHealthKit(weight: nil), calendar: Self.calendar)

        await assist.fetchLatestWeight()

        #expect(assist.state == .noData)
        #expect(assist.fetchedWeightKilograms == nil)
        // Never blames the user's permission — HealthKit does not disclose it.
        let message = assist.message ?? ""
        #expect(!message.contains("拒否"))
        #expect(!message.contains("許可"))
    }

    @Test
    func aNonPositiveWeightIsTreatedAsNoData() async {
        let assist = HealthKitInputAssist(client: FakeHealthKit(weight: 0), calendar: Self.calendar)
        await assist.fetchLatestWeight()
        #expect(assist.state == .noData)
        #expect(assist.fetchedWeightKilograms == nil)
    }

    @Test
    func aDeniedRequestStillProducesOnlyNeutralEmptiness() async {
        // A refused request yields no samples, which is indistinguishable from
        // having none. The result must be the ordinary empty state.
        let fake = FakeHealthKit(authorizationResult: false, weight: nil)
        let assist = HealthKitInputAssist(client: fake, calendar: Self.calendar)

        await assist.fetchLatestWeight()

        #expect(assist.state == .noData)
        #expect(fake.authorizationRequests == 1)
    }

    // MARK: - Availability

    @Test
    func anUnavailableDeviceNeverAsksForAuthorization() async {
        let fake = FakeHealthKit(isAvailable: false, weight: 70)
        let assist = HealthKitInputAssist(client: fake, calendar: Self.calendar)

        await assist.fetchLatestWeight()
        await assist.fetchSleep(for: Self.date(2026, 8, 12))

        #expect(assist.state == .unavailable)
        #expect(fake.authorizationRequests == 0)
        #expect(assist.isAvailable == false)
        #expect(assist.fetchedWeightKilograms == nil)
        #expect(assist.fetchedSleepMinutes == nil)
    }

    @Test
    func authorizationIsOnlyRequestedOnAnExplicitFetch() async {
        let fake = FakeHealthKit(weight: 70)
        _ = HealthKitInputAssist(client: fake, calendar: Self.calendar)
        // Constructing the assist — which is what a screen appearing does —
        // must never prompt.
        #expect(fake.authorizationRequests == 0)
    }

    // MARK: - Sleep aggregation

    @Test
    func sleepStagesAreSummed() {
        // Core → deep → REM back to back: 1h + 2h + 30m.
        let intervals = [
            Self.interval((2026, 8, 11, 23, 0), (2026, 8, 12, 0, 0)),
            Self.interval((2026, 8, 12, 0, 0), (2026, 8, 12, 2, 0)),
            Self.interval((2026, 8, 12, 2, 0), (2026, 8, 12, 2, 30)),
        ]
        #expect(SleepAggregator.totalMinutes(intervals) == 210)
    }

    @Test
    func overlappingSamplesAreCountedOnce() {
        // A watch and a phone reporting the same 3 hours.
        let watch = Self.interval((2026, 8, 11, 23, 0), (2026, 8, 12, 2, 0))
        let phone = Self.interval((2026, 8, 11, 23, 0), (2026, 8, 12, 2, 0))
        #expect(SleepAggregator.totalMinutes([watch, phone]) == 180)
    }

    @Test
    func partiallyOverlappingSourcesMergeIntoTheirUnion() {
        let a = Self.interval((2026, 8, 11, 23, 0), (2026, 8, 12, 1, 0))
        let b = Self.interval((2026, 8, 12, 0, 30), (2026, 8, 12, 3, 0))
        // 23:00–03:00 is four hours, not the 4.5 that adding would give.
        #expect(SleepAggregator.totalMinutes([a, b]) == 240)
        #expect(SleepAggregator.merged([a, b]).count == 1)
    }

    @Test
    func separateStretchesStaySeparate() {
        let first = Self.interval((2026, 8, 11, 23, 0), (2026, 8, 12, 1, 0))
        let second = Self.interval((2026, 8, 12, 3, 0), (2026, 8, 12, 5, 0))
        #expect(SleepAggregator.merged([first, second]).count == 2)
        #expect(SleepAggregator.totalMinutes([first, second]) == 240)
    }

    @Test
    func aNightCrossingMidnightIsNotCutInHalf() {
        let night = Self.interval((2026, 8, 11, 23, 30), (2026, 8, 12, 7, 0))
        #expect(SleepAggregator.totalMinutes([night]) == 450)
    }

    @Test
    func emptyInputYieldsZero() {
        #expect(SleepAggregator.totalMinutes([]) == 0)
        #expect(SleepAggregator.merged([]).isEmpty)
    }

    @Test
    func zeroLengthSamplesAreIgnored() {
        let empty = Self.interval((2026, 8, 12, 1, 0), (2026, 8, 12, 1, 0))
        #expect(SleepAggregator.merged([empty]).isEmpty)
        #expect(SleepAggregator.totalMinutes([empty]) == 0)
    }

    // MARK: - Which samples count

    @Test
    func onlyAsleepCategoriesCount() {
        #if canImport(HealthKit)
        // Asleep stages count.
        #expect(HealthKitClient.isAsleep(HKCategoryValueSleepAnalysis.asleepCore.rawValue))
        #expect(HealthKitClient.isAsleep(HKCategoryValueSleepAnalysis.asleepDeep.rawValue))
        #expect(HealthKitClient.isAsleep(HKCategoryValueSleepAnalysis.asleepREM.rawValue))
        #expect(HealthKitClient.isAsleep(HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue))
        // Lying down and being awake do not.
        #expect(!HealthKitClient.isAsleep(HKCategoryValueSleepAnalysis.inBed.rawValue))
        #expect(!HealthKitClient.isAsleep(HKCategoryValueSleepAnalysis.awake.rawValue))
        #endif
    }

    // MARK: - Night window

    @Test
    func theNightWindowSpansTheEveningBeforeUntilNoon() {
        let window = SleepAggregator.nightWindow(for: Self.date(2026, 8, 12), calendar: Self.calendar)
        #expect(window.start == Self.date(2026, 8, 11, 18, 0))
        #expect(window.end == Self.date(2026, 8, 12, 12, 0))
        // A normal night sits inside it.
        #expect(window.contains(Self.date(2026, 8, 11, 23, 30)))
        #expect(window.contains(Self.date(2026, 8, 12, 7, 0)))
        // An afternoon nap does not become "last night".
        #expect(!window.contains(Self.date(2026, 8, 12, 15, 0)))
    }

    @Test
    func sleepFetchUsesTheNightWindowAndMergesOverlap() async {
        let watch = Self.interval((2026, 8, 11, 23, 0), (2026, 8, 12, 6, 0))
        let phone = Self.interval((2026, 8, 12, 1, 0), (2026, 8, 12, 7, 0))
        let fake = FakeHealthKit(intervals: [watch, phone])
        let assist = HealthKitInputAssist(client: fake, calendar: Self.calendar)

        await assist.fetchSleep(for: Self.date(2026, 8, 12))

        #expect(assist.state == .filled)
        // 23:00 → 07:00 is eight hours once merged, not the 13 of a naive sum.
        #expect(assist.fetchedSleepMinutes == 480)
        #expect(fake.requestedWindows.first?.start == Self.date(2026, 8, 11, 18, 0))
    }

    @Test
    func noSleepSamplesReadAsNoData() async {
        let assist = HealthKitInputAssist(client: FakeHealthKit(intervals: []), calendar: Self.calendar)
        await assist.fetchSleep(for: Self.date(2026, 8, 12))
        #expect(assist.state == .noData)
        #expect(assist.fetchedSleepMinutes == nil)
    }

    // MARK: - Fetching never saves

    @Test
    func fetchingWritesNothingToTheDayLog() async throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let day = DayLog(date: Self.date(2026, 8, 12))
        context.insert(day)
        try context.save()

        let fake = FakeHealthKit(
            weight: 71.2,
            intervals: [Self.interval((2026, 8, 11, 23, 0), (2026, 8, 12, 7, 0))]
        )
        let assist = HealthKitInputAssist(client: fake, calendar: Self.calendar)

        await assist.fetchLatestWeight()
        await assist.fetchSleep(for: day.date)

        // Values are available to hand to the wheels…
        #expect(assist.fetchedWeightKilograms == 71.2)
        #expect(assist.fetchedSleepMinutes == 480)
        // …but nothing was recorded. Saving stays the user's explicit action.
        let stored = try context.fetch(FetchDescriptor<DayLog>())
        #expect(stored.count == 1)
        #expect(stored.first?.weightKg == nil)
        #expect(stored.first?.sleepMinutes == nil)
    }

    /// Manual entry keeps working untouched, with or without Health.
    @Test
    func manualEntryIsUnaffected() throws {
        let schema = Schema(versionedSchema: PulseCueSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let day = DayLog(date: Self.date(2026, 8, 12))
        context.insert(day)

        day.sleepMinutes = 415
        day.weightKg = 68.3
        try context.save()

        let stored = try #require(try context.fetch(FetchDescriptor<DayLog>()).first)
        #expect(stored.sleepMinutes == 415)
        #expect(stored.weightKg == 68.3)
    }
}
