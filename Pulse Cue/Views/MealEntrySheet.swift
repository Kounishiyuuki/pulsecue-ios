//
//  MealEntrySheet.swift
//  Pulse Cue
//
//  Created by Codex.
//
//  Modal editor for adding or editing a single meal entry.
//
//  Two creation flows are supported via `Mode`:
//
//    .add(source: .manual, slot:)
//      - Saved as `.confirmed` immediately. The user is recording
//        something they already ate, no AI involvement.
//
//    .add(source: .ai, slot:)
//      - The sheet shows a "AI 推定として保存" copy and the meal is
//        persisted as `.pending` with `source: .ai`. The actual
//        candidate is *locally synthesized* — no external AI API is
//        called. The user later reviews + 確定 from the AI 解析結果
//        section in `NutritionView`. This matches the privacy
//        boundary in `AICoachStub.swift`: nothing the model produces
//        is written back to DayLog without an explicit confirm tap.
//
//    .edit(MealEntry)
//      - Edit existing meal. Status is preserved unless the user
//        explicitly confirms from NutritionView.
//

import SwiftUI
import SwiftData

struct MealEntrySheet: View {
    enum Mode: Hashable, Identifiable {
        case add(source: MealSource, slot: MealSlot)
        case edit(MealEntry)

        var id: String {
            switch self {
            case .add(let source, let slot):
                return "add-\(source.rawValue)-\(slot.rawValue)"
            case .edit(let meal):
                return "edit-\(meal.id.uuidString)"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let mode: Mode

    @State private var slot: MealSlot
    @State private var name: String
    @State private var kcalText: String
    @State private var proteinText: String
    @State private var carbText: String
    @State private var fatText: String
    @State private var note: String

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .add(_, let slot):
            self._slot = State(initialValue: slot)
            self._name = State(initialValue: "")
            self._kcalText = State(initialValue: "")
            self._proteinText = State(initialValue: "")
            self._carbText = State(initialValue: "")
            self._fatText = State(initialValue: "")
            self._note = State(initialValue: "")
        case .edit(let meal):
            self._slot = State(initialValue: meal.slot)
            self._name = State(initialValue: meal.name)
            self._kcalText = State(initialValue: "\(meal.kcal)")
            self._proteinText = State(initialValue: meal.proteinGrams.map { "\($0)" } ?? "")
            self._carbText = State(initialValue: meal.carbGrams.map { "\($0)" } ?? "")
            self._fatText = State(initialValue: meal.fatGrams.map { "\($0)" } ?? "")
            self._note = State(initialValue: meal.note ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("時間帯", selection: $slot) {
                        ForEach(MealSlot.allCases) { slot in
                            Text(slot.label).tag(slot)
                        }
                    }
                    TextField("料理名（例：オートミール、焼き鮭定食）", text: $name)
                        .textInputAutocapitalization(.never)
                }

                Section {
                    LabeledContent("カロリー") {
                        HStack(spacing: 4) {
                            TextField("0", text: $kcalText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Text("kcal").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if isAIFlow {
                        Text("ここに入れた値は AI 推定の候補として保存されます。栄養画面で内容を確認してから「確定」してください。")
                    } else {
                        Text("確定済みとして保存され、今日の摂取カロリーに加算されます。")
                    }
                }

                Section("マクロ栄養素（任意）") {
                    macroField(label: "タンパク質", text: $proteinText)
                    macroField(label: "炭水化物", text: $carbText)
                    macroField(label: "脂質", text: $fatText)
                }

                Section("メモ（任意）") {
                    TextField("気付いたこと", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) { save() }
                        .disabled(!isFormValid)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Helpers

    private var isAIFlow: Bool {
        if case .add(let source, _) = mode { return source == .ai }
        if case .edit(let meal) = mode { return meal.source == .ai && meal.status == .pending }
        return false
    }

    private var navTitle: String {
        switch mode {
        case .add(let source, _):
            return source == .ai ? "AI で記録" : "手動で記録"
        case .edit:
            return "食事を編集"
        }
    }

    private var saveTitle: String {
        switch mode {
        case .add(let source, _):
            return source == .ai ? "推定を保存" : "保存"
        case .edit:
            return "保存"
        }
    }

    private var isFormValid: Bool {
        guard let kcal = Int(kcalText), kcal >= 0 else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty || isAIFlow
    }

    private func macroField(label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("0", text: text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                Text("g").foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let kcal = max(0, Int(kcalText) ?? 0)
        let p = Int(proteinText)
        let c = Int(carbText)
        let f = Int(fatText)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .add(let source, _):
            let resolvedName = trimmedName.isEmpty ? slot.label : trimmedName
            let entry = MealEntry(
                dayDate: Date(),
                slot: slot,
                name: resolvedName,
                kcal: kcal,
                proteinGrams: p,
                carbGrams: c,
                fatGrams: f,
                status: source == .ai ? .pending : .confirmed,
                source: source,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
            modelContext.insert(entry)
            // For manual confirmed entries, sync DayLog now. AI entries
            // wait for the explicit 確定 in NutritionView.
            if source == .manual {
                NutritionLedger.syncDayLogIntake(for: Date(), modelContext: modelContext)
            }
        case .edit(let meal):
            let oldStatus = meal.status
            meal.slotRaw = slot.rawValue
            meal.name = trimmedName.isEmpty ? slot.label : trimmedName
            meal.kcal = kcal
            meal.proteinGrams = p
            meal.carbGrams = c
            meal.fatGrams = f
            meal.note = trimmedNote.isEmpty ? nil : trimmedNote
            // Edits never auto-promote a pending meal to confirmed —
            // promotion happens only via the explicit 確定 action.
            if oldStatus == .confirmed {
                NutritionLedger.syncDayLogIntake(for: meal.dayDate, modelContext: modelContext)
            }
        }
        dismiss()
    }
}
