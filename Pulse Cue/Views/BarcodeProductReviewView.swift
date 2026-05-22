//
//  BarcodeProductReviewView.swift
//  Pulse Cue
//
//  Review screen for a barcode product lookup. This is the
//  confirmation gate of the barcode feature: a `ProductLookupResult`
//  is only ever a *candidate* until the user confirms it here.
//
//  Boundaries (locked for this PR):
//   - No MealEntry is created and DayLog is never updated until the
//     user taps the explicit 「記録する」 button. Backing out of the
//     screen discards the candidate with no side effect.
//   - Every looked-up field is editable. Open Food Facts data is
//     community-contributed and often incomplete, so the screen
//     works the same whether the lookup found a product or not — in
//     the not-found case the fields simply start empty.
//   - On confirm the meal is saved as `.confirmed` with
//     `source: .barcode` and DayLog intake is synced, mirroring the
//     manual-entry flow in `MealEntrySheet`.
//

import SwiftUI
import SwiftData

struct BarcodeProductReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// The looked-up candidate. When the product was not found this
    /// still carries the scanned `barcode` with empty nutrition
    /// fields, so the user can record the item manually.
    let candidate: ProductLookupResult
    /// Whether the lookup actually matched a product. Drives only the
    /// explanatory copy — the editing flow is identical either way.
    let productFound: Bool
    /// Invoked after a MealEntry has been saved, so the presenter
    /// (the scanner sheet) can dismiss the whole flow.
    let onSaved: () -> Void

    @State private var slot: MealSlot
    @State private var name: String
    @State private var kcalText: String
    @State private var proteinText: String
    @State private var carbText: String
    @State private var fatText: String
    @State private var note: String

    init(
        candidate: ProductLookupResult,
        productFound: Bool,
        onSaved: @escaping () -> Void
    ) {
        self.candidate = candidate
        self.productFound = productFound
        self.onSaved = onSaved
        _slot = State(initialValue: .snack)
        _name = State(initialValue: candidate.name ?? "")
        _kcalText = State(initialValue: candidate.kcal.map { "\($0)" } ?? "")
        _proteinText = State(initialValue: candidate.proteinGrams.map { "\($0)" } ?? "")
        _carbText = State(initialValue: "")
        _fatText = State(initialValue: "")
        _note = State(initialValue: "")
    }

    var body: some View {
        Form {
            lookupSummarySection
            slotAndNameSection
            caloriesSection
            macroSection
            noteSection
        }
        .navigationTitle("商品を確認")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("記録する") { save() }
                    .disabled(!isFormValid)
            }
        }
    }

    // MARK: - Sections

    private var lookupSummarySection: some View {
        Section {
            LabeledContent("バーコード") {
                Text(candidate.barcode)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let serving = candidate.servingDescription {
                LabeledContent("1食分の目安") {
                    Text(serving).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("読み取り結果")
        } footer: {
            if productFound {
                Text("Open Food Facts の値を読み込みました。栄養成分は 100g あたりの目安です。実際に食べた量に合わせて修正してから記録してください。")
            } else {
                Text("この商品の情報は見つかりませんでした。内容を入力して記録できます。")
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
            TextField("商品名", text: $name)
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

    private var isFormValid: Bool {
        guard let kcal = Int(kcalText), kcal >= 0 else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Save

    /// Creates the MealEntry only here, on the explicit confirm tap.
    /// This is the single point where the barcode flow writes to the
    /// store and syncs DayLog — nothing before this touched either.
    private func save() {
        let entry = ConfirmedMealEntryFactory.make(
            day: Date(),
            slot: slot,
            name: name,
            kcalText: kcalText,
            proteinText: proteinText,
            carbText: carbText,
            fatText: fatText,
            note: note,
            source: .barcode
        )
        modelContext.insert(entry)
        // Mirrors the manual-entry path in MealEntrySheet: a confirmed
        // meal is reflected in the day's intake immediately.
        NutritionLedger.syncDayLogIntake(for: Date(), modelContext: modelContext)
        onSaved()
    }
}
