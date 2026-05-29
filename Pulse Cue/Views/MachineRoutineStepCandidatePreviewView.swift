//
//  MachineRoutineStepCandidatePreviewView.swift
//  Pulse Cue
//
//  Read-only sheet that previews a `RoutineStepCandidate` built from a
//  machine catalog entry. This is the "candidate" step of the eventual
//  candidate → review → confirm → save flow, so it is intentionally
//  inert: there is NO save button, it never creates a `Routine`/`Step`,
//  never touches a `ModelContext`, and does no networking/AI. The copy
//  makes the not-yet-saved status explicit.
//

import SwiftUI

struct MachineRoutineStepCandidatePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let candidate: RoutineStepCandidate

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundLayer.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerCard
                        menuCard
                        if let notes = candidate.notes {
                            notesCard(notes)
                        }
                        deferredNotice
                        Color.clear.frame(height: 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("種目候補")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(candidate.sourceLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(candidate.exerciseName)
                    .font(.system(size: 22, weight: .bold))
                if !candidate.bodyParts.isEmpty {
                    chipRow(candidate.bodyParts.map(\.displayName))
                }
            }
        }
    }

    // MARK: - Sets / reps / rest

    private var menuCard: some View {
        cardSection(title: "セット・回数の目安") {
            VStack(alignment: .leading, spacing: 8) {
                if candidate.hasMenuDefaults {
                    if let setsReps = candidate.setsAndRepsText {
                        menuLine(icon: "repeat", text: setsReps)
                    }
                    if let rest = candidate.restText {
                        menuLine(icon: "timer", text: rest)
                    }
                    Text("※ あくまで目安です。体調や経験に合わせて調整してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else {
                    Text(MachineExerciseTemplate.fallbackMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Notes

    private func notesCard(_ notes: String) -> some View {
        cardSection(title: "メモ") {
            Text(notes)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Deferred notice

    private var deferredNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("この候補はまだ保存されません。ルーティンへの追加は今後対応予定です。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Reusable building blocks

    private func cardSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)
            card { content() }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    private func chipRow(_ items: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
    }

    private func menuLine(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text)
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        let colors: [Color] = colorScheme == .dark
            ? [Color(red: 0.05, green: 0.07, blue: 0.12),
               Color(red: 0.07, green: 0.06, blue: 0.13)]
            : [Color(red: 0.93, green: 0.96, blue: 1.00),
               Color(red: 0.99, green: 0.96, blue: 1.00)]
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview("With defaults") {
    MachineRoutineStepCandidatePreviewView(
        candidate: RoutineStepCandidate(
            entry: MachineCatalogEntry(
                id: "bench_press",
                displayName: "ベンチプレス",
                bodyParts: [.chest, .arms],
                secondaryMuscles: [.shoulders],
                setupNotes: "ベンチに仰向けになり、肩甲骨を寄せて胸を張ります。",
                defaultSets: 3,
                defaultReps: 8...12,
                defaultRestSeconds: 90
            )
        )
    )
}

#Preview("No defaults") {
    MachineRoutineStepCandidatePreviewView(
        candidate: RoutineStepCandidate(
            entry: MachineCatalogEntry(
                id: "pec_deck",
                displayName: "ペックデック",
                bodyParts: [.chest]
            )
        )
    )
}
