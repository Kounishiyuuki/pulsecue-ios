//
//  HealthKitClient.swift
//  Pulse Cue
//
//  Read-only HealthKit access, kept behind a small protocol so the rest of
//  the app — and every test — can work without the framework or a device.
//
//  PulseCue's manual entry stays the source of truth. Nothing here writes to
//  HealthKit, writes to SwiftData, or saves anything: a fetch only produces a
//  value for the user to look at and then save themselves.
//
//  Privacy: HealthKit deliberately does not reveal whether *read* access was
//  denied — a denied type simply returns no samples. So "no samples" and
//  "not permitted" are indistinguishable here, and this layer never claims
//  the user refused anything. Callers must phrase an empty result neutrally.
//

import Foundation

#if canImport(HealthKit)
import HealthKit
#endif

/// A half-open span of sleep, `start..<end`.
struct SleepInterval: Equatable, Sendable {
    let start: Date
    let end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Pure aggregation, so the rules can be tested without HealthKit.
enum SleepAggregator {

    /// Total time actually asleep, counting overlapping stretches once.
    ///
    /// Several sources (a watch and a phone, or a sleep app) routinely report
    /// the same night, and one source emits a separate sample per stage. Adding
    /// their durations would double-count, so the intervals are merged into a
    /// union first.
    static func totalMinutes(_ intervals: [SleepInterval]) -> Int {
        Int(totalSeconds(intervals) / 60)
    }

    static func totalSeconds(_ intervals: [SleepInterval]) -> TimeInterval {
        merged(intervals).reduce(0) { $0 + $1.duration }
    }

    /// Overlapping or touching intervals combined into the smallest set that
    /// covers the same time, in chronological order.
    static func merged(_ intervals: [SleepInterval]) -> [SleepInterval] {
        let sorted = intervals
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }

        var result: [SleepInterval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                // Overlapping or adjacent: extend, never add.
                if interval.end > current.end {
                    current = SleepInterval(start: current.start, end: interval.end)
                }
            } else {
                result.append(current)
                current = interval
            }
        }
        result.append(current)
        return result
    }

    /// The night whose sleep belongs to `date`: 18:00 the previous evening
    /// through 12:00 that day.
    ///
    /// A `DayLog` is keyed by the start of its day, but nobody's sleep starts
    /// there — it starts the evening before. Reading only the calendar day
    /// would cut every night in half at midnight, so the window deliberately
    /// spans it and stops at noon, before an afternoon nap could be counted
    /// as last night.
    static func nightWindow(for date: Date, calendar: Calendar = .current) -> DateInterval {
        let dayStart = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .hour, value: -6, to: dayStart) ?? dayStart
        let end = calendar.date(byAdding: .hour, value: 12, to: dayStart) ?? dayStart
        return DateInterval(start: start, end: max(start, end))
    }
}

/// The read-only surface the app uses. Implemented for real by
/// `HealthKitClient` and faked in tests.
@MainActor
protocol HealthKitReading: AnyObject {
    /// Whether this device has HealthKit at all (iPad and Mac Catalyst may
    /// not). False means the assist UI stays out of the way.
    var isAvailable: Bool { get }

    /// Presents the system sheet if it has not been shown for these types.
    /// The result says the request *completed*, never that it was granted —
    /// HealthKit does not disclose read denials.
    func requestReadAuthorization() async -> Bool

    /// Most recent body mass in kilograms, or `nil` when there is nothing to
    /// read (no samples, or read access not granted — indistinguishable).
    func latestBodyMassKilograms() async -> Double?

    /// Asleep stretches overlapping `window`. In-bed and awake samples are
    /// excluded by the implementation; overlaps are the caller's to merge.
    func asleepIntervals(in window: DateInterval) async -> [SleepInterval]
}

#if canImport(HealthKit)

@MainActor
final class HealthKitClient: HealthKitReading {
    static let shared = HealthKitClient()

    private let store = HKHealthStore()

    private var bodyMassType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .bodyMass)
    }

    private var sleepType: HKCategoryType? {
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Read-only: the `toShare` set is empty, so the app can never write to
    /// Health and the system sheet shows no write toggles.
    func requestReadAuthorization() async -> Bool {
        guard isAvailable else { return false }
        var readTypes: Set<HKObjectType> = []
        if let bodyMassType { readTypes.insert(bodyMassType) }
        if let sleepType { readTypes.insert(sleepType) }
        guard !readTypes.isEmpty else { return false }

        return await withCheckedContinuation { continuation in
            store.requestAuthorization(toShare: [], read: readTypes) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    func latestBodyMassKilograms() async -> Double? {
        guard isAvailable, let bodyMassType else { return nil }
        let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: bodyMassType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [newestFirst]
            ) { _, samples, _ in
                let kilograms = (samples?.first as? HKQuantitySample)?
                    .quantity
                    .doubleValue(for: .gramUnit(with: .kilo))
                continuation.resume(returning: kilograms)
            }
            store.execute(query)
        }
    }

    func asleepIntervals(in window: DateInterval) async -> [SleepInterval] {
        guard isAvailable, let sleepType else { return [] }
        // `.strictStartDate` is intentionally NOT used: a night that starts
        // before the window must still be counted for its overlapping part.
        let predicate = HKQuery.predicateForSamples(
            withStart: window.start,
            end: window.end,
            options: []
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                let intervals = (samples as? [HKCategorySample] ?? [])
                    .filter { Self.isAsleep($0.value) }
                    .map {
                        // Clip to the window so a long sample cannot leak time
                        // from the previous night into this one.
                        SleepInterval(
                            start: max($0.startDate, window.start),
                            end: min($0.endDate, window.end)
                        )
                    }
                continuation.resume(returning: intervals)
            }
            store.execute(query)
        }
    }

    /// Only genuinely-asleep categories count. `inBed` is time lying down, not
    /// sleep, and `awake` is the opposite of it — including either inflates
    /// the night.
    nonisolated static func isAsleep(_ value: Int) -> Bool {
        guard let category = HKCategoryValueSleepAnalysis(rawValue: value) else { return false }
        switch category {
        case .asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified:
            return true
        case .inBed, .awake:
            return false
        @unknown default:
            // A future stage is more likely to be a sleep stage than not, but
            // guessing would silently change totals — so it is not counted.
            return false
        }
    }
}

#else

/// HealthKit is unavailable at compile time; every call is a no-op so the
/// rest of the app builds and behaves exactly as it does without Health.
@MainActor
final class HealthKitClient: HealthKitReading {
    static let shared = HealthKitClient()
    var isAvailable: Bool { false }
    func requestReadAuthorization() async -> Bool { false }
    func latestBodyMassKilograms() async -> Double? { nil }
    func asleepIntervals(in window: DateInterval) async -> [SleepInterval] { [] }
}

#endif
