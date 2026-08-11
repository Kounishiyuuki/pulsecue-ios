//
//  HealthKitInputAssist.swift
//  Pulse Cue
//
//  Drives the "ヘルスケアから取得" affordance next to the sleep and weight
//  wheels. It fetches a value and stops there — the wheels move, and only the
//  user's own "保存" writes anything. This type never touches SwiftData,
//  Settings, or a `DayLog`.
//
//  Split out of the view so the whole flow (availability → request → fetch →
//  outcome) can be tested against a fake client, with no HealthKit and no
//  device.
//

import Foundation
import Combine

@MainActor
final class HealthKitInputAssist: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        /// A value was read and handed to the input control.
        case filled
        /// Nothing came back. HealthKit does not disclose read denials, so
        /// this covers "no data recorded" and "not permitted" alike and must
        /// never be presented as a refusal.
        case noData
        /// This device has no HealthKit.
        case unavailable
    }

    @Published private(set) var state: State = .idle

    /// Last value read, in the unit the input control expects. Held only for
    /// the caller to apply; nothing here persists it.
    private(set) var fetchedWeightKilograms: Double?
    private(set) var fetchedSleepMinutes: Int?

    private let client: any HealthKitReading
    private let calendar: Calendar

    init(client: any HealthKitReading = HealthKitClient.shared, calendar: Calendar = .current) {
        self.client = client
        self.calendar = calendar
    }

    var isAvailable: Bool { client.isAvailable }

    /// Neutral, user-facing description of the current state. Deliberately
    /// avoids blaming a permission.
    var message: String? {
        switch state {
        case .idle: return nil
        case .loading: return "ヘルスケアを確認中…"
        case .filled: return "ヘルスケアから取得しました"
        case .noData: return "取得できるデータがありません"
        case .unavailable: return "この端末ではヘルスケアを利用できません"
        }
    }

    func fetchLatestWeight() async {
        guard await beginFetch() else { return }
        let kilograms = await client.latestBodyMassKilograms()
        guard let kilograms, kilograms > 0 else {
            fetchedWeightKilograms = nil
            state = .noData
            return
        }
        fetchedWeightKilograms = kilograms
        state = .filled
    }

    /// Reads the night that belongs to `date` (see `SleepAggregator.nightWindow`)
    /// and merges overlapping stretches so two sources reporting the same
    /// night are counted once.
    func fetchSleep(for date: Date) async {
        guard await beginFetch() else { return }
        let window = SleepAggregator.nightWindow(for: date, calendar: calendar)
        let intervals = await client.asleepIntervals(in: window)
        let minutes = SleepAggregator.totalMinutes(intervals)
        guard minutes > 0 else {
            fetchedSleepMinutes = nil
            state = .noData
            return
        }
        fetchedSleepMinutes = minutes
        state = .filled
    }

    /// Availability check, then the authorization request — only ever from an
    /// explicit user tap, never at launch. Returns whether to continue.
    private func beginFetch() async -> Bool {
        guard client.isAvailable else {
            state = .unavailable
            return false
        }
        state = .loading
        // A failed request still falls through to the query: the result is
        // simply empty, and "empty" is all we are allowed to conclude.
        _ = await client.requestReadAuthorization()
        return true
    }
}
