//
//  RunnerPersistence.swift
//  Pulse Cue
//
//  Where a workout in progress is left when the app goes away, and whose it is.
//
//  This used to be one key for the device. That was right while there were no
//  accounts and wrong the moment there were: B starting a workout overwrote
//  the single slot, so A came back to a half-finished session with no position
//  to return to. Scoping the *rows* was not enough — the resume metadata
//  pointing at them was still shared.
//
//  So there is one slot per scope. Guest keeps the original key, which is not
//  a convenience: state written before this version was written by a device
//  with no account, and guest is what that data is. Reading it as guest is the
//  same rule the workout rows themselves migrate under, so no in-progress
//  workout is lost to the upgrade — and none is quietly attributed to whoever
//  signs in next.
//
//  `.undetermined` has no slot at all. There is no honest key to write under
//  while the app does not yet know whose session it is.
//

import Foundation

struct RunnerPersistentState: Codable {
    var sessionId: UUID
    var routineId: UUID
    var phase: RunnerPhase
    var stepIndex: Int
    var setIndex: Int
    var currentReps: Int? = nil
    var restDeadline: Date?
    var lastUpdatedAt: Date
}

struct RunnerPersistence {
    /// The pre-account key, which is now the guest slot. Never reused for an
    /// account: the account slots are suffixed with the account's own UUID —
    /// the server's, never a provider subject or an address.
    private static let guestKey = "runner.persistent.state"

    /// The slot for a scope, or nil when there is no honest one.
    static func key(for scope: WorkoutDataScope) -> String? {
        switch scope {
        case .guest:
            return guestKey
        case let .account(id):
            return "\(guestKey).\(id.uuidString)"
        case .undetermined:
            return nil
        }
    }

    static func save(_ state: RunnerPersistentState, scope: WorkoutDataScope = .guest) {
        guard let key = key(for: scope) else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load(scope: WorkoutDataScope = .guest) -> RunnerPersistentState? {
        guard let key = key(for: scope),
              let data = UserDefaults.standard.data(forKey: key)
        else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(RunnerPersistentState.self, from: data)
    }

    /// Clears one scope's slot and no other.
    ///
    /// Finishing or abandoning a workout says something about that account's
    /// workout. Somebody else's half-finished session is not part of it, and
    /// neither is the guest data sitting alongside.
    static func clear(scope: WorkoutDataScope = .guest) {
        guard let key = key(for: scope) else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
