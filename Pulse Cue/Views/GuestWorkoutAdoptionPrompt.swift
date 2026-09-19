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
                Text("この端末にゲストとして記録したトレーニング履歴を、このアカウントのものにします。他のアカウントの記録は変わりません。")
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
        guard !answered.contains(id) else { return }
        // Nothing to hand over means nothing to ask about.
        let guests = (try? AccountScopedSyncStore().guestSessions(in: modelContext)) ?? []
        guard !guests.isEmpty else { return }
        pendingAccountID = id
    }

    private func adopt() {
        guard let id = pendingAccountID else { return }
        pendingAccountID = nil
        do {
            try AccountScopedSyncStore().adoptGuestWorkoutData(for: id, in: modelContext)
            markAnswered(id)
        } catch {
            // Say nothing succeeded, because nothing did: adoption saves once,
            // so the guest rows are still guest rows. The account is left
            // alone — a failed transfer is not a reason to end a session.
            failed = true
        }
    }

    private func decline() {
        guard let id = pendingAccountID else { return }
        pendingAccountID = nil
        markAnswered(id)
    }

    private var answered: Set<UUID> {
        Set(answeredRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func markAnswered(_ id: UUID) {
        var ids = answered
        ids.insert(id)
        answeredRaw = ids.map(\.uuidString).sorted().joined(separator: ",")
    }
}
