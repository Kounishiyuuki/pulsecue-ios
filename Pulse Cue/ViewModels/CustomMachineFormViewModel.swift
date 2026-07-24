//
//  CustomMachineFormViewModel.swift
//  Pulse Cue
//
//  Drives the one reusable create/edit form for user-authored gym
//  machines. Holds the draft locally and validates it; nothing is
//  written to SwiftData until `save(modelContext:)` runs, which happens
//  only from the form's explicit save action — never while typing.
//
//  Availability is deliberately NOT edited here. It is managed in one
//  place (the machine-selection list, staged until「プランを保存」) so the
//  user never has two competing ways to switch a machine on and off.
//  Editing preserves whatever availability the record already has.
//

import Foundation
import Combine
import SwiftData

@MainActor
final class CustomMachineFormViewModel: ObservableObject {

    enum Mode: Equatable {
        case create
        case edit
    }

    enum State: Equatable {
        case idle
        case saved
        case error(String)
    }

    let gym: Gym
    let mode: Mode
    /// Persistent id of the record being edited; `nil` when creating.
    private let editingId: UUID?

    @Published var displayName: String = ""
    @Published var selectedBodyParts: Set<BodyPart> = []
    @Published var equipmentType: EquipmentType?
    @Published var notes: String = ""
    @Published private(set) var state: State = .idle
    /// Errors stay hidden until the user has actually engaged with the
    /// field, so an untouched empty form is not shouting at them.
    @Published private(set) var hasEditedName = false

    /// Body-part chips, in the same order the rest of the app uses.
    let bodyPartChoices: [BodyPart] = [
        .chest, .back, .shoulders, .arms, .legs, .core, .fullBody
    ]

    init(gym: Gym, editing machine: CustomMachine? = nil) {
        self.gym = gym
        if let machine {
            self.mode = .edit
            self.editingId = machine.id
            self.displayName = machine.displayName
            self.selectedBodyParts = Set(machine.resolvedBodyParts)
            self.equipmentType = machine.resolvedEquipmentType
            self.notes = machine.notes ?? ""
        } else {
            self.mode = .create
            self.editingId = nil
        }
    }

    // MARK: - Validation

    var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isNameValid: Bool { !trimmedName.isEmpty }
    var isBodyPartsValid: Bool { !selectedBodyParts.isEmpty }
    var canSave: Bool { isNameValid && isBodyPartsValid }

    /// Inline message shown under the name field, or `nil` when fine.
    var nameError: String? {
        guard hasEditedName, !isNameValid else { return nil }
        return "マシン名を入力してください。"
    }

    /// Inline message shown under the body-part chips, or `nil`.
    var bodyPartsError: String? {
        isBodyPartsValid ? nil : "鍛える部位を1つ以上選んでください。"
    }

    var title: String {
        mode == .create ? "カスタムマシンを追加" : "カスタムマシンを編集"
    }

    var saveButtonTitle: String {
        mode == .create ? "追加する" : "変更を保存"
    }

    // MARK: - Mutations (local draft only)

    func nameChanged() {
        hasEditedName = true
    }

    func toggleBodyPart(_ part: BodyPart) {
        if selectedBodyParts.contains(part) {
            selectedBodyParts.remove(part)
        } else {
            selectedBodyParts.insert(part)
        }
    }

    func isSelected(_ part: BodyPart) -> Bool {
        selectedBodyParts.contains(part)
    }

    /// Body parts in canonical order — the repository normalizes and
    /// dedupes again, this just keeps the draft deterministic.
    var orderedBodyParts: [BodyPart] {
        BodyPart.allCases.filter { selectedBodyParts.contains($0) }
    }

    // MARK: - Explicit save

    /// The only place this form writes. Validation runs first so an
    /// invalid draft can never reach the store.
    func save(modelContext: ModelContext) {
        hasEditedName = true
        guard canSave else {
            state = .error("入力内容を確認してください。")
            return
        }

        let repository = GymRepository(modelContext: modelContext)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch mode {
            case .create:
                try repository.addCustomMachine(
                    to: gym,
                    displayName: trimmedName,
                    bodyParts: orderedBodyParts,
                    equipmentType: equipmentType,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes
                )
            case .edit:
                guard let editingId, let existing = repository.customMachine(withId: editingId) else {
                    state = .error("編集対象のマシンが見つかりませんでした。")
                    return
                }
                try repository.updateCustomMachine(
                    existing,
                    displayName: trimmedName,
                    bodyParts: orderedBodyParts,
                    equipmentType: .some(equipmentType),
                    notes: .some(trimmedNotes.isEmpty ? nil : trimmedNotes)
                )
            }
            state = .saved
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? CustomMachineError else {
            return "保存できませんでした。"
        }
        switch error {
        case .gymNotFound: return "ジムが見つかりませんでした。"
        case .emptyDisplayName: return "マシン名を入力してください。"
        case .noBodyParts: return "鍛える部位を1つ以上選んでください。"
        case .notFound: return "編集対象のマシンが見つかりませんでした。"
        }
    }
}
