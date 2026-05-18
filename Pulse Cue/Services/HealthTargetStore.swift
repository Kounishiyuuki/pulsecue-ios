//
//  HealthTargetStore.swift
//  Pulse Cue
//
//  UserDefaults-backed @MainActor ObservableObject that persists the
//  user's `HealthTargetSettings`. Chosen over a SwiftData @Model so
//  this PR stays additive — no schema version bump, no migration.
//
//  Storage format:
//    - One JSON blob at key `health.targetSettings.v1`.
//    - Keys/values that don't decode cleanly fall back to
//      `HealthTargetSettings.empty` rather than crashing.
//    - `dateOverrides` is encoded with an explicit
//      `yyyy-MM-dd` (POSIX, UTC-anchored startOfDay) string key so the
//      JSON stays human-readable and tolerant of legacy / future
//      Calendar locale changes.
//
//  Resolver consumers (TodayView, HealthSummaryView, future cards)
//  should read `store.settings` once and pass it into
//  `HealthTargetResolver.resolve(...)`. The store does not perform
//  resolution itself — that's the resolver's job.
//

import Foundation
import Combine

@MainActor
final class HealthTargetStore: ObservableObject {

    @Published private(set) var settings: HealthTargetSettings

    private let defaults: UserDefaults
    private let storageKey: String
    private let isoDateFormatter: DateFormatter

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "health.targetSettings.v1",
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        self.isoDateFormatter = formatter

        self.settings = Self.load(
            from: defaults,
            key: storageKey,
            dateFormatter: formatter,
        )
    }

    // MARK: - Mutations

    func updateDefaults(_ targets: HealthTargets) {
        settings.defaults = targets
        persist()
    }

    func updateWeekdayOverride(_ weekday: HealthTargetWeekday, targets: HealthTargets) {
        if targets.isEmpty {
            settings.weekdayOverrides.removeValue(forKey: weekday)
        } else {
            settings.weekdayOverrides[weekday] = targets
        }
        persist()
    }

    func clearWeekdayOverride(_ weekday: HealthTargetWeekday) {
        settings.weekdayOverrides.removeValue(forKey: weekday)
        persist()
    }

    func updateDateOverride(_ date: Date, targets: HealthTargets, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        if targets.isEmpty {
            settings.dateOverrides.removeValue(forKey: day)
        } else {
            settings.dateOverrides[day] = targets
        }
        persist()
    }

    func clearDateOverride(_ date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        settings.dateOverrides.removeValue(forKey: day)
        persist()
    }

    /// Resets all stored target configuration. Primarily for tests and
    /// a future "reset to defaults" affordance.
    func resetAll() {
        settings = .empty
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - Persistence

    private func persist() {
        let encoded = Encoded(
            defaults: settings.defaults,
            weekdayOverrides: settings.weekdayOverrides.reduce(into: [:]) { acc, entry in
                acc[String(entry.key.rawValue)] = entry.value
            },
            dateOverrides: settings.dateOverrides.reduce(into: [:]) { acc, entry in
                acc[isoDateFormatter.string(from: entry.key)] = entry.value
            }
        )
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(
        from defaults: UserDefaults,
        key: String,
        dateFormatter: DateFormatter,
    ) -> HealthTargetSettings {
        guard let data = defaults.data(forKey: key),
              let encoded = try? JSONDecoder().decode(Encoded.self, from: data) else {
            return .empty
        }
        let weekdayOverrides: [HealthTargetWeekday: HealthTargets] =
            encoded.weekdayOverrides.reduce(into: [:]) { acc, entry in
                guard let raw = Int(entry.key),
                      let weekday = HealthTargetWeekday(rawValue: raw) else { return }
                acc[weekday] = entry.value
            }
        let dateOverrides: [Date: HealthTargets] =
            encoded.dateOverrides.reduce(into: [:]) { acc, entry in
                guard let date = dateFormatter.date(from: entry.key) else { return }
                acc[date] = entry.value
            }
        return HealthTargetSettings(
            defaults: encoded.defaults,
            weekdayOverrides: weekdayOverrides,
            dateOverrides: dateOverrides,
        )
    }

    /// JSON wire format. String keys so the on-disk shape stays stable
    /// across enum or Calendar changes.
    private struct Encoded: Codable {
        var defaults: HealthTargets
        var weekdayOverrides: [String: HealthTargets]
        var dateOverrides: [String: HealthTargets]
    }
}
