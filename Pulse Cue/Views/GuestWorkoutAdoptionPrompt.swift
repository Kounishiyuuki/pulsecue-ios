//
//  GuestWorkoutAdoptionPrompt.swift
//  Pulse Cue
//
//  The one moment guest training history can change hands, and the only place
//  the app asks for it.
//
//  Adoption is not automatic on sign-in, and that is the whole design. A phone
//  can be borrowed, shared, or handed to a friend at the gym who signs in to
//  check something; "you signed in, so this is yours now" quietly moves one
//  person's training into another person's account, and does it at the moment
//  nobody is looking at their history. So the transfer is a question with a
//  clear "no", asked once per account, and the answer is remembered.
//
//  The question is only asked when there is something to ask about — guest
//  workouts actually exist on this device. Signing in on a fresh install shows
//  nothing.
//
//  Rows owned by another account are not in scope and cannot be: the operation
//  behind "引き継ぐ" fetches `ownerAccountID == nil` and nothing else.
//
//  Health data (day logs, meals, profile) rides on the same question rather
//  than a second alert: "この端末の記録をこのアカウントに引き継ぐ" is one
//  decision about one device. Both halves land in one save — health
//  adoption's commit runs the workout adoption — so a failure leaves both as
//  guest data. Each half is remembered separately, because an account asked
//  about workouts by an earlier build has not yet been asked about health.
//
//  A plain `.alert`. Two buttons and a sentence is exactly what Alert is for,
//  and a hand-built sheet here would lose the system's focus order, Dynamic
//  Type behaviour and VoiceOver handling to gain nothing.
//

import SwiftUI
import SwiftData

extension View {
    /// Asks, once per account, whether guest workouts on this device should be
    /// carried into the account that just signed in.
    func guestWorkoutAdoptionPrompt() -> some View {
        modifier(GuestWorkoutAdoptionPrompt())
    }
}

private struct GuestWorkoutAdoptionPrompt: ViewModifier {
    @EnvironmentObject private var dataScope: WorkoutDataScopeResolver
    @Environment(\.modelContext) private var modelContext

    @State private var pendingAccountID: UUID?
    @State private var failed = false

    /// Accounts already asked on this device, accepted or declined. Stored so
    /// a decline is a decision rather than a question that returns every
    /// launch.
    @AppStorage("sync.adoptionAnsweredAccountIDs") private var answeredRaw = ""
    @AppStorage("sync.healthAdoptionAnsweredAccountIDs") private var healthAnsweredRaw = ""

    /// Which halves the pending question covers.
    @State private var pendingWorkout = false
    @State private var pendingHealth = false

    func body(content: Content) -> some View {
        content
            .onAppear { evaluate(dataScope.scope) }
            .onChange(of: dataScope.scope) { _, scope in evaluate(scope) }
            .alert(
                "ゲストの記録を引き継ぎますか？",
                isPresented: Binding(
                    get: { pendingAccountID != nil },
                    set: { if !$0 { pendingAccountID = nil } }
                )
            ) {
                Button("引き継ぐ") { adopt() }
                Button("引き継がない", role: .cancel) { decline() }
            } message: {
                Text("この端末にゲストとして記録した\(pendingSubject)を、このアカウントのものにします。他のアカウントの記録は変わりません。")
            }
            .alert("引き継げませんでした", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("記録はゲストのまま残っています。もう一度お試しください。")
            }
    }

    private func evaluate(_ scope: WorkoutDataScope) {
        guard case let .account(id) = scope else {
            pendingAccountID = nil
            return
        }
        // Nothing to hand over means nothing to ask about.
        let workout = !Self.ids(answeredRaw).contains(id)
            && !((try? AccountScopedSyncStore().guestSessions(in: modelContext)) ?? []).isEmpty
        let health = !Self.ids(healthAnsweredRaw).contains(id)
            && ((try? HealthDataAdoptionStore().hasGuestHealthData(in: modelContext)) ?? false)
        guard workout || health else { return }
        pendingWorkout = workout
        pendingHealth = health
        pendingAccountID = id
    }

    private var pendingSubject: String {
        switch (pendingWorkout, pendingHealth) {
        case (true, true): return "トレーニング・食事・体重や睡眠の記録"
        case (false, true): return "食事・体重や睡眠の記録"
        default: return "トレーニング履歴"
        }
    }

    private func adopt() {
        guard let id = pendingAccountID else { return }
        pendingAccountID = nil
        let workout = pendingWorkout
        let health = pendingHealth
        do {
            if health {
                // One save for both halves: the health commit runs the workout
                // adoption, whose own save carries the health changes too (or
                // which restores its rows and throws). It saves nothing when it
                // had nothing to move, and only then is a save of ours needed.
                try HealthDataAdoptionStore(commit: { context in
                    let moved = workout
                        ? try AccountScopedSyncStore().adoptGuestWorkoutData(for: id, in: context)
                        : .nothing
                    if moved == .nothing { try context.save() }
                }).adoptGuestHealthData(for: id, in: modelContext)
            } else if workout {
                try AccountScopedSyncStore().adoptGuestWorkoutData(for: id, in: modelContext)
            }
            markAnswered(id, workout: workout, health: health)
        } catch {
            // Say nothing succeeded, because nothing did: adoption saves once,
            // so the guest rows — workouts and health alike — are still guest
            // rows. The account is left
            // alone — a failed transfer is not a reason to end a session.
            failed = true
        }
    }

    private func decline() {
        guard let id = pendingAccountID else { return }
        pendingAccountID = nil
        markAnswered(id, workout: pendingWorkout, health: pendingHealth)
    }

    private static func ids(_ raw: String) -> Set<UUID> {
        Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private static func adding(_ id: UUID, to raw: String) -> String {
        var ids = ids(raw)
        ids.insert(id)
        return ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    /// Only the halves that were asked: a workout-only question is not an
    /// answer about health data that did not exist yet.
    private func markAnswered(_ id: UUID, workout: Bool, health: Bool) {
        if workout { answeredRaw = Self.adding(id, to: answeredRaw) }
        if health { healthAnsweredRaw = Self.adding(id, to: healthAnsweredRaw) }
    }
}
