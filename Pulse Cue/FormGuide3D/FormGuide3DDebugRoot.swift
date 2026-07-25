//
//  FormGuide3DDebugRoot.swift
//  Pulse Cue
//
//  DEBUG-ONLY isolated root for the deterministic 3D Form Guide route
//  (`-pulsecue-ui-test-form-guide-3d`). The whole type is compiled out of
//  Release. It exists so visual/screenshot review can reach the guide
//  without the multi-step gym→plan navigation, while having ZERO normal
//  side effects:
//
//   - it is NOT `ContentView` → `SampleDataSeeder` / the UI-test gym seeder
//     never run,
//   - it never calls onboarding completion → no `UserDefaults` writes,
//   - the app's ModelContainer is in-memory for this route → the user's
//     persistent V4 store is never opened or written.
//
//  Dismissal uses real mutable `@State` (not `.constant`) so the guide can
//  close to a simple fixture root and be reopened.
//

#if DEBUG
import SwiftUI

struct FormGuide3DDebugRoot: View {
    let exerciseId: String
    /// Optional frozen cycle progress for deterministic screenshots.
    let staticProgress: Float?

    @State private var presentedId: ExerciseID?

    init(exerciseId: String, staticProgress: Float? = nil) {
        self.exerciseId = exerciseId
        self.staticProgress = staticProgress
        _presentedId = State(initialValue: ExerciseID(rawValue: exerciseId))
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Form Guide 3D デバッグルート")
                    .font(.headline)
                Text("exerciseId: \(exerciseId)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                Button("フォームガイドを開く") {
                    presentedId = ExerciseID(rawValue: exerciseId)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("debug-open-form-guide")
            }
            .padding()
        }
        // Mutable state: closing the guide sets `presentedId` to nil and
        // returns to this fixture root; the button reopens it.
        .sheet(item: $presentedId) { id in
            ExerciseGuideView(exerciseId: id, debugStaticProgress: staticProgress)
        }
    }
}
#endif
