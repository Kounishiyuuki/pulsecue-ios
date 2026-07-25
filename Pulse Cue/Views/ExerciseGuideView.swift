//
//  ExerciseGuideView.swift
//  Pulse Cue
//
//  Form Guide. For the 10 MVP-guided exercises this now shows an actual
//  RealityKit 3D movement demo (`Guide3DSection` → `Exercise3DViewer`)
//  ABOVE the authored Japanese text sections. The 3D is additive: the text
//  guide remains the authoritative instruction and renders even if the 3D
//  scene fails to construct. Exercises without a motion profile show text
//  only.
//
//  It reads nothing and writes nothing — opening or dismissing it creates
//  no `Routine`/`Step` and mutates no repository state. It is theme-aware
//  (system colors) and built for Dynamic Type + VoiceOver.
//

import SwiftUI

struct ExerciseGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let exerciseId: ExerciseID
    /// DEBUG-only: freeze the 3D demo at a fixed progress for deterministic
    /// screenshots. Always `nil` on production paths.
    var debugStaticProgress: Float? = nil

    private var exercise: Exercise? { ExerciseLibrary.exercise(for: exerciseId) }
    private var guide: ExerciseGuide? { FormGuideLibrary.guide(for: exerciseId) }
    private var motionProfile: ExerciseMotionProfile? { ExerciseMotionLibrary.profile(for: exerciseId) }

    var body: some View {
        NavigationStack {
            Group {
                if let exercise, let guide {
                    content(exercise: exercise, guide: guide)
                } else {
                    unavailable
                }
            }
            .navigationTitle("フォームガイド")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    // MARK: - Content

    private func content(exercise: Exercise, guide: ExerciseGuide) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(exercise: exercise)

                // 3D movement demo (additive). The text sections below remain
                // the authoritative instruction and render even if 3D fails.
                if let motionProfile {
                    Guide3DSection(profile: motionProfile, reduceMotion: reduceMotion, staticProgress: debugStaticProgress)
                }

                section(title: "基本の動き", systemImage: "figure.strengthtraining.traditional") {
                    numberedList(guide.instructions)
                }
                section(title: "よくあるミス", systemImage: "exclamationmark.triangle") {
                    bulletList(guide.commonMistakes, bullet: "•")
                }
                section(title: "チェックポイント", systemImage: "checkmark.circle") {
                    bulletList(guide.safetyNotes, bullet: "✓")
                }

                disclaimer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exercise.displayName)
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            // Target body parts as readable text (not color-coded).
            FlowChips(labels: exercise.bodyParts.map(\.displayName))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("対象部位: " + exercise.bodyParts.map(\.displayName).joined(separator: "、"))

            if let equipmentText = equipmentContext(for: exercise) {
                Label(equipmentText, systemImage: "dumbbell")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func numberedList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.accentColor))
                        .accessibilityHidden(true)
                    Text(item)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("手順\(index + 1): \(item)")
            }
        }
    }

    private func bulletList(_ items: [String], bullet: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(bullet)
                        .font(.body.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(item)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var disclaimer: some View {
        Text(FormGuideLibrary.sharedDisclaimer)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
            )
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "ガイドは準備中です",
            systemImage: "book.closed",
            description: Text("この種目のフォームガイドはまだ用意されていません。")
        )
    }

    // MARK: - Helpers

    /// Compatible equipment names from `MachineCatalog`, joined for a
    /// short "対応マシン" line. `nil` when none resolve.
    private func equipmentContext(for exercise: Exercise) -> String? {
        let names = exercise.compatibleMachineIds
            .compactMap { MachineCatalog.entry(for: $0)?.displayName }
        guard !names.isEmpty else { return nil }
        return "対応マシン: " + names.joined(separator: "、")
    }
}

/// Owns the RealityKit scene controller lifecycle for one guide viewing.
/// Isolated as its own view so the `@StateObject` is created only when a
/// motion profile exists, and is torn down on disappear. If the 3D scene
/// fails to construct, a concise non-blocking fallback is shown while the
/// surrounding text guide keeps working.
private struct Guide3DSection: View {
    let profile: ExerciseMotionProfile
    let reduceMotion: Bool
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @StateObject private var controller: Exercise3DSceneController

    init(profile: ExerciseMotionProfile, reduceMotion: Bool, staticProgress: Float? = nil) {
        self.profile = profile
        self.reduceMotion = reduceMotion
        _controller = StateObject(
            wrappedValue: Exercise3DSceneController(
                profile: profile, reduceMotion: reduceMotion, staticProgress: staticProgress
            )
        )
    }

    var body: some View {
        Group {
            if controller.sceneFailed {
                fallback
            } else {
                Exercise3DViewer(controller: controller)
            }
        }
        // Keep the controller in sync if Reduce Motion changes at runtime so
        // the badge and the RealityKit playback never disagree.
        .onChange(of: envReduceMotion) { _, newValue in
            controller.setReduceMotion(newValue)
        }
        .onDisappear { controller.teardown() }
    }

    private var fallback: some View {
        Label(
            "3Dデモを表示できませんでした。下の説明を参考にしてください。",
            systemImage: "cube.transparent"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

/// Simple wrapping chip row for target body parts. Text-only, no
/// color-only meaning, wraps under Dynamic Type.
private struct FlowChips: View {
    let labels: [String]

    var body: some View {
        // A LazyVGrid adaptive layout keeps chips wrapping on narrow
        // screens and at large text sizes without manual width math.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 64), spacing: 8, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}
