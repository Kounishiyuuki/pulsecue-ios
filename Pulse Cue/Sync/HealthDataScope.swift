//
//  HealthDataScope.swift
//  Pulse Cue
//
//  Whose health data — day logs, meals, profile — this device is showing.
//
//  It is the workout scope, not a copy of it. "Guest", "account A" and
//  "undetermined" have to mean exactly the same thing on the Training tab and
//  on the Nutrition tab: a second enum resolved by a second resolver could
//  disagree with the first for one launch, and that launch would show account
//  A's workouts next to guest meals. One type and one resolver make that
//  disagreement unrepresentable. The health-specific vocabulary lives here
//  so `WorkoutDataScope.swift` stays about workouts.
//
//  The resolver is `WorkoutDataScopeResolver`; its policy (server-confirmed
//  internal UUID only, fail closed on an unreadable id, `.undetermined` while
//  a session is being confirmed) applies unchanged.
//

import Foundation

typealias HealthDataScope = WorkoutDataScope

extension WorkoutDataScope {
    /// Whether a day log, meal or profile may be created right now.
    ///
    /// The same rule as workouts, for the same reason: an undetermined scope
    /// would have to guess an owner, and "guest for now" strands an account
    /// holder's entry in guest data.
    var canCreateHealthData: Bool {
        self != .undetermined
    }

    /// The scope a row already belongs to — for following up a change to an
    /// existing meal or log in its own owner's data, whatever scope happens
    /// to be current when the edit lands.
    static func owning(_ ownerAccountID: UUID?) -> HealthDataScope {
        ownerAccountID.map(HealthDataScope.account) ?? .guest
    }

    func visible(_ logs: [DayLog]) -> [DayLog] {
        logs.filter { matches(ownerAccountID: $0.ownerAccountID) }
    }

    func visible(_ meals: [MealEntry]) -> [MealEntry] {
        meals.filter { matches(ownerAccountID: $0.ownerAccountID) }
    }

    func visible(_ profiles: [UserProfile]) -> [UserProfile] {
        profiles.filter { matches(ownerAccountID: $0.ownerAccountID) }
    }
}

/// A value computed for one scope, readable only while that scope is current.
///
/// Screens cache the latest weigh-in and refresh it from `onChange`, which
/// runs after the render that noticed the change. Without the scope attached,
/// that one render after switching from account A to B shows A's weight under
/// B. Reading through `value(in:)` makes the stale figure unreadable instead
/// of briefly visible.
struct HealthScopedValue<Value> {
    let scope: HealthDataScope
    let value: Value

    func value(in current: HealthDataScope) -> Value? {
        scope == current ? value : nil
    }
}

/// UserDefaults keys for per-person health settings — favorite meals, manual
/// targets — namespaced the way `HealthDataScope` namespaces rows.
///
/// These blobs were device-global before accounts existed, so whoever signed
/// in saw, edited and computed with whoever came before. The pre-account
/// value is guest data: it is copied into the guest namespace only, never
/// into an account (signing in is not consent to take it), and the legacy key
/// is left in place so a downgraded build still finds it.
///
/// Not part of guest adoption: these are re-entry conveniences and settings,
/// not records, and they live outside the SwiftData transaction adoption
/// commits in.
enum HealthScopedDefaults {
    /// `<base>.guest`, `<base>.account.<UUID>`, or nil while undetermined —
    /// there is no key to read or write until the scope is known.
    static func key(_ base: String, for scope: HealthDataScope) -> String? {
        switch scope {
        case .guest: return "\(base).guest"
        case let .account(id): return "\(base).account.\(id.uuidString)"
        case .undetermined: return nil
        }
    }

    /// The scope's stored data. For guest, a pre-account value under `base`
    /// is copied in first (once — afterwards the guest key exists).
    static func data(_ base: String, for scope: HealthDataScope, in defaults: UserDefaults) -> Data? {
        guard let key = key(base, for: scope) else { return nil }
        if scope == .guest, defaults.object(forKey: key) == nil,
           let legacy = defaults.data(forKey: base) {
            defaults.set(legacy, forKey: key)
        }
        return defaults.data(forKey: key)
    }
}
