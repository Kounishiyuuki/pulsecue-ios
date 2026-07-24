//
//  ExerciseGuideView.swift
//  Pulse Cue
//
//  Text-based Form Guide. This PR intentionally ships no 3D: the screen is
//  useful today through authored Japanese guidance, and is laid out so a
//  future iOS-17-compatible RealityKit viewer can be inserted ABOVE the
//  text (see `viewerPlaceholderAnchor`) without redesigning it. There is
//  NO blank 3D box, mannequin, "coming soon", or placeholder animation.
//
//  It reads nothing and writes nothing — opening or dismissing it creates
//  no `Routine`/`Step` and mutates no repository state. It is theme-aware
//  (system colors) and built for Dynamic Type + VoiceOver.
//

import SwiftUI

struct ExerciseGuideView: View {
    @Environment(\.dismiss) private var dismiss

    let exerciseId: ExerciseID

    private var exercise: Exercise? { ExerciseLibrary.exercise(for: exerciseId) }
    private var guide: ExerciseGuide? { FormGuideLibrary.guide(for: exerciseId) }

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
                // Anchor where a future 3D viewer is inserted. No visible
                // placeholder is drawn today, per the no-fake-3D rule.
                viewerPlaceholderAnchor

                header(exercise: exercise)

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

    @ViewBuilder
    private var viewerPlaceholderAnchor: some View {
        EmptyView()
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
