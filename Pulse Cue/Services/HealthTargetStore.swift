//
//  HealthTargetStore.swift
//  Pulse Cue
//
//  UserDefaults-backed @MainActor ObservableObject that persists the
//  user's `HealthTargetSettings`. Chosen over a SwiftData @Model so
//  this PR stays additive — no schema version bump, no migration.
//
//  Storage format:
//    - One JSON blob per `HealthDataScope`, under
//      `HealthScopedDefaults.key("health.targetSettings.v1", for:)`. The
//      bare `health.targetSettings.v1` key is the pre-account,
//      device-global blob; it seeds the guest scope only.
//    - Keys/values that don't decode cleanly fall back to
//      `HealthTargetSettings.empty` rather than crashing.
//    - `dateOverrides` is encoded with an explicit
//      `yyyy-MM-dd` (POSIX, UTC-anchored startOfDay) string key so the
//      JSON stays human-readable and tolerant of legacy / future
//      Calendar locale changes.
//
//  The store holds one scope's settings at a time. `settings(in:)` returns
//  `.empty` for any other scope and writes for another scope are dropped, so
//  an A → B switch on the same instance cannot show, compute with or
//  overwrite A's targets under B before `use(_:)` reloads.
//
//  Resolver consumers (TodayView, HealthSummaryView, future cards)
//  should read `store.settings(in:)` once and pass it into
//  `HealthTargetResolver.resolve(...)`. The store does not perform
//  resolution itself — that's the resolver's job.
//

import Foundation
import Combine

@MainActor
final class HealthTargetStore: ObservableObject {

    @Published private var loaded: HealthScopedValue<HealthTargetSettings>

    private let defaults: UserDefaults
    private let storageKey: String
    private let isoDateFormatter: DateFormatter

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "health.targetSettings.v1",
        scope: HealthDataScope = .undetermined,
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        self.isoDateFormatter = formatter

        self.loaded = HealthScopedValue(
            scope: scope,
            value: Self.load(from: defaults, key: storageKey, scope: scope, dateFormatter: formatter)
        )
    }

    /// Loads `scope`'s settings. Called when the current scope changes.
    func use(_ scope: HealthDataScope) {
        guard loaded.scope != scope else { return }
        loaded = HealthScopedValue(
            scope: scope,
            value: Self.load(from: defaults, key: storageKey, scope: scope, dateFormatter: isoDateFormatter)
        )
    }

    /// `scope`'s settings, or `.empty` while the store holds another scope's.
    func settings(in scope: HealthDataScope) -> HealthTargetSettings {
        loaded.value(in: scope) ?? .empty
    }

    // MARK: - Mutations

    func updateDefaults(_ targets: HealthTargets, in scope: HealthDataScope) {
        mutate(scope) { $0.defaults = targets }
    }

    func updateWeekdayOverride(_ weekday: HealthTargetWeekday, targets: HealthTargets, in scope: HealthDataScope) {
        mutate(scope) { settings in
            if targets.isEmpty {
                settings.weekdayOverrides.removeValue(forKey: weekday)
            } else {
                settings.weekdayOverrides[weekday] = targets
            }
        }
    }

    func clearWeekdayOverride(_ weekday: HealthTargetWeekday, in scope: HealthDataScope) {
        mutate(scope) { $0.weekdayOverrides.removeValue(forKey: weekday) }
    }

    func updateDateOverride(_ date: Date, targets: HealthTargets, in scope: HealthDataScope, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        mutate(scope) { settings in
            if targets.isEmpty {
                settings.dateOverrides.removeValue(forKey: day)
            } else {
                settings.dateOverrides[day] = targets
            }
        }
    }

    func clearDateOverride(_ date: Date, in scope: HealthDataScope, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        mutate(scope) { $0.dateOverrides.removeValue(forKey: day) }
    }

    /// Resets `scope`'s target configuration. Primarily for tests and
    /// a future "reset to defaults" affordance.
    func resetAll(in scope: HealthDataScope) {
        guard let key = HealthScopedDefaults.key(storageKey, for: scope),
              loaded.scope == scope else { return }
        loaded = HealthScopedValue(scope: scope, value: .empty)
        defaults.removeObject(forKey: key)
    }

    /// Applies `change` only to the loaded scope, and only once it is known.
    private func mutate(_ scope: HealthDataScope, _ change: (inout HealthTargetSettings) -> Void) {
        guard let key = HealthScopedDefaults.key(storageKey, for: scope),
              var settings = loaded.value(in: scope) else { return }
        change(&settings)
        loaded = HealthScopedValue(scope: scope, value: settings)
        persist(settings, key: key)
    }

    // MARK: - Persistence

    private func persist(_ settings: HealthTargetSettings, key: String) {
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
        defaults.set(data, forKey: key)
    }

    private static func load(
        from defaults: UserDefaults,
        key: String,
        scope: HealthDataScope,
        dateFormatter: DateFormatter,
    ) -> HealthTargetSettings {
        guard let data = HealthScopedDefaults.data(key, for: scope, in: defaults),
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
