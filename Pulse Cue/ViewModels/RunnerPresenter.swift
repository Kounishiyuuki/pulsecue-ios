//
//  RunnerPresenter.swift
//  Pulse Cue
//
//  UI-presentation state for the Runner full-screen cover, kept *separate*
//  from the workout's domain state (`RunnerViewModel.isRunning`).
//
//  Contract:
//   - The workout itself is owned solely by RunnerViewModel. This type never
//     starts, ends, or mutates a session — it only decides whether the cover
//     is on screen.
//   - `syncPresentation(isRunning:)` mirrors the domain state: a workout
//     becoming active presents the cover; becoming inactive dismisses it.
//     ContentView calls this on every `isRunning` change and once at launch
//     (so a session recovered from disk re-presents its Runner).
//   - `resume(isRunning:)` is the explicit "ワークアウトを再開" path: it
//     re-presents the cover for an *already active* workout WITHOUT touching
//     domain state, so no new Session is ever created. When nothing is
//     running it is a no-op (never presents an empty Runner).
//
//  Because the cover is bound to `isRunnerCovered` and marked
//  `.interactiveDismissDisabled` while active, presentation cannot silently
//  desync from an active workout.
//

import Foundation
import Combine

@MainActor
final class RunnerPresenter: ObservableObject {
    /// Whether the Runner full-screen cover is currently shown.
    @Published var isRunnerCovered: Bool = false

    /// Mirror the authoritative workout state onto presentation.
    func syncPresentation(isRunning: Bool) {
        isRunnerCovered = isRunning
    }

    /// Explicit user-initiated resume. Only re-presents an existing active
    /// workout; creates/mutates nothing. No-op when nothing is running.
    func resume(isRunning: Bool) {
        guard isRunning else { return }
        isRunnerCovered = true
    }
}
