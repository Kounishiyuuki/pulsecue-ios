//
//  NutritionLabelReviewView.swift
//  Pulse Cue
//
//  Review screen for a nutrition-label OCR scan. This is the
//  confirmation gate of the OCR feature: a `NutritionLabelCandidate`
//  is only ever a *candidate* until the user confirms it here.
//
//  Boundaries (locked for this PR):
//   - No MealEntry is created and DayLog is never updated until the
//     user taps the explicit 「食事として保存」 button. Backing out of
//     the screen discards the candidate with no side effect.
//   - Every recognized field is editable. OCR is lossy, so the
//     screen works the same whether text was recognized or not — in
//     the not-recognized case the fields simply start empty.
//   - On confirm the meal is saved as `.confirmed` with
//     `source: .ocr` and DayLog intake is synced through
//     `NutritionLedger`, mirroring the manual-entry and barcode
//     review flows.
//

import SwiftUI
import SwiftData

struct NutritionLabelReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// The OCR candidate. When nothing was recognized this still
    /// carries empty fields so the user can record the item manually.
    let candidate: NutritionLabelCandidate
    /// Whether OCR actually recognized usable values. Drives only the
    /// explanatory copy — the editing flow is identical either way.
    let textRecognized: Bool
    /// Invoked after a MealEntry has been saved, so the presenter
    /// (the OCR sheet) can dismiss the whole flow.
    let onSaved: () -> Void

    @State private var slot: MealSlot
    @State private var name: String
    @State private var kcalText: String
    @State private var proteinText: String
    @State private var carbText: String
    @State private var fatText: String
    @State private var note: String

    init(
        candidate: NutritionLabelCandidate,
        textRecognized: Bool,
        onSaved: @escaping () -> Void
    ) {
        self.candidate = candidate
        self.textRecognized = textRecognized
        self.onSaved = onSaved
        _slot = State(initialValue: .snack)
        _name = State(initialValue: "")
        _kcalText = State(initialValue: candidate.kcal.map { "\($0)" } ?? "")
        _proteinText = State(initialValue: candidate.proteinGrams.map { "\($0)" } ?? "")
        _carbText = State(initialValue: "")
        _fatText = State(initialValue: "")
        _note = State(initialValue: "")
    }

    var body: some View {
        Form {
            summarySection
            slotAndNameSection
            caloriesSection
            macroSection
            noteSection
        }
        .navigationTitle("栄養表示の結果を確認")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("食事として保存") { save() }
                    .disabled(!isFormValid)
            }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            LabeledContent("カロリー") {
                Text(candidate.kcal.map { "\($0) kcal" } ?? "未取得")
                    .foregroundStyle(candidate.kcal == nil ? .secondary : .primary)
            }
            LabeledContent("タンパク質") {
                Text(candidate.proteinGrams.map { "\($0) g" } ?? "未取得")
                    .foregroundStyle(candidate.proteinGrams == nil ? .secondary : .primary)
            }
        } header: {
            Text("読み取り結果")
        } footer: {
            if textRecognized {
                Text("読み取った数値は正確でない場合があります。保存前に確認してください。")
            } else {
                Text("栄養表示を読み取れませんでした。内容を入力して記録できます。")
            }
        }
    }

    private var slotAndNameSection: some View {
        Section {
            Picker("時間帯", selection: $slot) {
                ForEach(MealSlot.allCases) { slot in
                    Text(slot.label).tag(slot)
                }
            }
            TextField("食事名", text: $name)
                .textInputAutocapitalization(.never)
        } footer: {
            Text("確定済みの食事として、選んだ時間帯に記録されます。")
        }
    }

    private var caloriesSection: some View {
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
            Text("記録すると今日の摂取カロリーに加算されます。")
        }
    }

    private var macroSection: some View {
        Section("マクロ栄養素（任意）") {
            macroField(label: "タンパク質", text: $proteinText)
            macroField(label: "炭水化物", text: $carbText)
            macroField(label: "脂質", text: $fatText)
        }
    }

    private var noteSection: some View {
        Section("メモ（任意）") {
            TextField("気付いたこと", text: $note, axis: .vertical)
                .lineLimit(2...4)
        }
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

    // MARK: - Validation

    /// The 「食事として保存」 button is enabled only once calories hold
    /// a valid non-negative number. Protein and name may be left
    /// empty — protein is optional and a blank name falls back to the
    /// slot label.
    private var isFormValid: Bool {
        guard let kcal = Int(kcalText) else { return false }
        return kcal >= 0
    }

    // MARK: - Save

    /// Creates the MealEntry only here, on the explicit confirm tap.
    /// This is the single point where the OCR flow writes to the
    /// store and syncs DayLog — nothing before this touched either.
    private func save() {
        let entry = Self.makeConfirmedEntry(
            day: Date(),
            slot: slot,
            name: name,
            kcalText: kcalText,
            proteinText: proteinText,
            carbText: carbText,
            fatText: fatText,
            note: note
        )
        modelContext.insert(entry)
        // Mirrors the manual-entry path: a confirmed meal is reflected
        // in the day's intake immediately, via the canonical ledger.
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: modelContext)
        onSaved()
    }

    /// Builds the confirmed `MealEntry` an OCR review produces from
    /// the form's (string-typed) fields. Pure — it touches no SwiftUI
    /// or SwiftData state — so the confirm logic stays unit-testable
    /// without a view host; `save()` is its only production caller
    /// and owns the insert + DayLog sync that follow.
    ///
    /// Behavior locked for this PR:
    ///  - `status` is always `.confirmed` and `source` always `.ocr`:
    ///    a reviewed OCR meal is never a draft.
    ///  - a blank name falls back to the slot label and a blank note
    ///    to `nil`, matching the manual-entry path in `MealEntrySheet`.
    ///  - a non-numeric calorie field counts as 0; `isFormValid`
    ///    gates the UI so a real value is always present in practice.
    static func makeConfirmedEntry(
        day: Date,
        slot: MealSlot,
        name: String,
        kcalText: String,
        proteinText: String,
        carbText: String,
        fatText: String,
        note: String
    ) -> MealEntry {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return MealEntry(
            dayDate: day,
            slot: slot,
            name: trimmedName.isEmpty ? slot.label : trimmedName,
            kcal: max(0, Int(kcalText) ?? 0),
            proteinGrams: Int(proteinText),
            carbGrams: Int(carbText),
            fatGrams: Int(fatText),
            status: .confirmed,
            source: .ocr,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
    }
}
