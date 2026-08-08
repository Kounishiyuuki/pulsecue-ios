//
//  ExerciseReplacementSheet.swift
//  Pulse Cue
//
//  Reusable "種目を変更" sheet shared by the Preview and the Runner. It only
//  presents candidates it is handed (ranked by `WorkoutPlanGenerator.
//  alternatives`) and reports the chosen one back — it owns no ranking, no
//  persistence, and no session state. Candidate metadata (body parts,
//  equipment, "same movement" relation) is read from the existing
//  `MachineCatalog`; custom machines simply show a カスタム tag.
//

import SwiftUI

struct ExerciseReplacementSheet: View {
    /// Display name of the exercise being replaced (for the header).
    let originalName: String
    /// Canonical machine id of the original, used only to compute the
    /// "same movement" relation label.
    let originalMachineId: String
    /// Pre-ranked candidates (may be empty → no-alternative state).
    let candidates: [GeneratedExercise]
    let onSelect: (GeneratedExercise) -> Void

    @Environment(\.dismiss) private var dismiss

    private var originalMovement: MovementPattern? {
        MachineCatalog.entry(for: originalMachineId)?.movementPattern
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PulseAtmosphericBackground()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        if candidates.isEmpty {
                            noCandidateCard
                        } else {
                            ForEach(candidates) { candidate in
                                candidateButton(candidate)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("種目を変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("「\(originalName)」の代わりに")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("このジムで使える種目に置き換えます。セット・レップ・休憩は引き継ぎます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Candidate card

    private func candidateButton(_ candidate: GeneratedExercise) -> some View {
        Button {
            onSelect(candidate)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(candidate.exerciseName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if isSameMovement(candidate) {
                        relationTag("同じ動作")
                    }
                }
                HStack(spacing: 8) {
                    if let parts = bodyPartLine(candidate) {
                        metaLabel(parts, systemImage: "target")
                    }
                    metaLabel(equipmentLabel(candidate), systemImage: "dumbbell")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AppTheme.separator, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("replacement-candidate")
        .accessibilityLabel("\(candidate.exerciseName)に変更")
    }

    private func relationTag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(AppTheme.accentSoft))
    }

    private func metaLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - No-candidate state

    private var noCandidateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("代替種目が見つかりません", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("このジムで利用できる代替種目がありません。マシンを追加するか、元の種目のまま続けてください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Metadata helpers

    private func isSameMovement(_ candidate: GeneratedExercise) -> Bool {
        guard let original = originalMovement,
              let entry = MachineCatalog.entry(for: candidate.machineId)?.movementPattern else { return false }
        return original == entry
    }

    private func bodyPartLine(_ candidate: GeneratedExercise) -> String? {
        guard let entry = MachineCatalog.entry(for: candidate.machineId) else { return nil }
        let parts = BodyPart.allCases
            .filter { entry.bodyParts.contains($0) }
            .map(\.displayName)
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private func equipmentLabel(_ candidate: GeneratedExercise) -> String {
        guard let entry = MachineCatalog.entry(for: candidate.machineId) else { return "カスタム" }
        switch entry.equipmentType {
        case .machine: return "マシン"
        case .cable: return "ケーブル"
        case .freeWeight: return "フリーウェイト"
        case .bodyweight: return "自重"
        case .cardioMachine: return "有酸素マシン"
        case .none: return "マシン"
        }
    }
}
