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
//  decision about one device. `AccountLocalDataAdoptionStore` preflights both
//  halves before applying either and saves once, so a failure leaves both as
//  guest data. Each half is remembered separately, because an account asked
//  about workouts by an earlier build has not yet been asked about health.
//
//  The guest profile alone does not raise the question, but once it is asked
//  the profile goes with the rest — unless the account already has one, which
//  stays authoritative. Favorite meals and manual targets are per-scope
//  settings and are not part of this; the copy does not claim them.
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

    @State private var pending: GuestAdoptionConsent.Question?
    @State private var failed = false

    /// Accounts already asked on this device, accepted or declined. Stored so
    /// a decline is a decision rather than a question that returns every
    /// launch.
    @AppStorage(GuestAdoptionConsent.workoutAnsweredKey) private var answeredRaw = ""
    @AppStorage(GuestAdoptionConsent.healthAnsweredKey) private var healthAnsweredRaw = ""

    func body(content: Content) -> some View {
        content
            .onAppear { evaluate(dataScope.scope) }
            .onChange(of: dataScope.scope) { _, scope in evaluate(scope) }
            .alert(
                "ゲストの記録を引き継ぎますか？",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                )
            ) {
                Button("引き継ぐ") { adopt() }
                Button("引き継がない", role: .cancel) { decline() }
            } message: {
                Text("この端末にゲストとして記録した\(pending?.subject ?? "")を、このアカウントのものにします。他のアカウントの記録は変わりません。")
            }
            .alert("引き継げませんでした", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("記録はゲストのまま残っています。もう一度お試しください。")
            }
    }

    private var answers: GuestAdoptionConsent.Answers {
        get { .init(workoutRaw: answeredRaw, healthRaw: healthAnsweredRaw) }
        nonmutating set {
            answeredRaw = newValue.workoutRaw
            healthAnsweredRaw = newValue.healthRaw
        }
    }

    private func evaluate(_ scope: WorkoutDataScope) {
        guard case let .account(id) = scope else {
            pending = nil
            return
        }
        pending = GuestAdoptionConsent.question(for: id, answers: answers, in: modelContext)
    }

    private func adopt() {
        guard let question = pending else { return }
        pending = nil
        var updated = answers
        do {
            try GuestAdoptionConsent.accept(question, answers: &updated, in: modelContext)
            answers = updated
        } catch {
            // Say nothing succeeded, because nothing did: the rows — workouts
            // and health alike — are still guest rows, and the question stays
            // unanswered so it can be retried. The account is left alone — a
            // failed transfer is not a reason to end a session.
            failed = true
        }
    }

    private func decline() {
        guard let question = pending else { return }
        pending = nil
        answers = answers.marking(question)
    }
}

/// The question's logic, apart from the alert, so its contract is testable:
/// what is asked, what accepting moves, and which answers are recorded when.
enum GuestAdoptionConsent {

    static let workoutAnsweredKey = "sync.adoptionAnsweredAccountIDs"
    static let healthAnsweredKey = "sync.healthAdoptionAnsweredAccountIDs"

    /// One pending question for one account. `profile` is the guest profile
    /// riding along with an unanswered health half; it never raises the
    /// question on its own.
    struct Question: Equatable {
        let accountID: UUID
        let workout: Bool
        let health: Bool
        let profile: Bool

        var subject: String {
            var parts: [String] = []
            if workout { parts.append("トレーニング") }
            if health { parts.append("食事記録・体重や睡眠") }
            if profile { parts.append("プロフィール") }
            return parts.joined(separator: "・")
        }
    }

    /// The per-domain "already asked" sets, as stored.
    struct Answers: Equatable {
        var workoutRaw: String
        var healthRaw: String

        func answeredWorkout(_ id: UUID) -> Bool { Self.ids(workoutRaw).contains(id) }
        func answeredHealth(_ id: UUID) -> Bool { Self.ids(healthRaw).contains(id) }

        /// Only the halves that were asked: a workout-only question is not an
        /// answer about health data that did not exist yet.
        func marking(_ question: Question) -> Answers {
            var next = self
            if question.workout { next.workoutRaw = Self.adding(question.accountID, to: workoutRaw) }
            if question.health { next.healthRaw = Self.adding(question.accountID, to: healthRaw) }
            return next
        }

        /// Forgets `id` in both halves — for an account deleted from this
        /// device, whose answers no longer describe anybody.
        func removing(_ id: UUID) -> Answers {
            Answers(workoutRaw: Self.removing(id, from: workoutRaw), healthRaw: Self.removing(id, from: healthRaw))
        }

        private static func ids(_ raw: String) -> Set<UUID> {
            Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        }

        private static func adding(_ id: UUID, to raw: String) -> String {
            var ids = ids(raw)
            ids.insert(id)
            return ids.map(\.uuidString).sorted().joined(separator: ",")
        }

        private static func removing(_ id: UUID, from raw: String) -> String {
            var ids = ids(raw)
            ids.remove(id)
            return ids.map(\.uuidString).sorted().joined(separator: ",")
        }
    }

    /// The question to ask `accountID` now, or nil when there is nothing
    /// unanswered to hand over.
    static func question(for accountID: UUID, answers: Answers, in context: ModelContext) -> Question? {
        let workout = !answers.answeredWorkout(accountID)
            && !((try? AccountScopedSyncStore().guestSessions(in: context)) ?? []).isEmpty
        let healthUnanswered = !answers.answeredHealth(accountID)
        let health = healthUnanswered
            && ((try? HealthDataAdoptionStore().hasGuestHealthData(in: context)) ?? false)
        guard workout || health else { return nil }
        let profile = healthUnanswered
            && ((try? HealthDataAdoptionStore().wouldAdoptGuestProfile(into: accountID, in: context)) ?? false)
        return Question(accountID: accountID, workout: workout, health: health, profile: profile)
    }

    /// Adopts what `question` covers in one transaction, then records the
    /// answer. A throw records nothing, so the question can be asked again.
    static func accept(
        _ question: Question,
        answers: inout Answers,
        in context: ModelContext,
        store: AccountLocalDataAdoptionStore = AccountLocalDataAdoptionStore()
    ) throws {
        try store.adoptGuestData(
            workout: question.workout,
            health: question.health || question.profile,
            for: question.accountID,
            in: context
        )
        answers = answers.marking(question)
    }
}
