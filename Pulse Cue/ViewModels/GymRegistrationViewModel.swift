//
//  GymRegistrationViewModel.swift
//  Pulse Cue
//
//  Two-field input + save state for registering a new gym. The
//  optional `officialUrl` is validated lazily here (http/https only,
//  must parse via `URL`) so the future import flow doesn't need a
//  second validation pass for the most common cases. SwiftData
//  persistence is delegated to `GymRepository`.
//

import Foundation
import Combine
import SwiftData

@MainActor
final class GymRegistrationViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case saving
        case saved(gymId: UUID)
        case error(String)
    }

    @Published var name: String = ""
    @Published var officialUrl: String = ""
    @Published private(set) var state: State = .idle

    private var modelContext: ModelContext?
    private var repository: GymRepository? {
        modelContext.map(GymRepository.init(modelContext:))
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSave: Bool {
        !trimmedName.isEmpty && state != .saving
    }

    /// Saves the gym and reports the new id back via `.saved`. Marks
    /// the new gym as active by default; the user can switch later
    /// from the hub screen.
    func save() {
        guard let repository else {
            state = .error("内部エラー: モデル未初期化")
            return
        }
        guard !trimmedName.isEmpty else {
            state = .error("ジム名を入力してください")
            return
        }

        let urlInput = officialUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlInput.isEmpty, !isValidPublicUrl(urlInput) {
            state = .error("公式URLは http または https で始まる必要があります")
            return
        }

        state = .saving
        let gym = repository.createGym(
            name: trimmedName,
            officialUrl: urlInput.isEmpty ? nil : urlInput,
            makeActive: true
        )
        state = .saved(gymId: gym.id)
    }

    private func isValidPublicUrl(_ input: String) -> Bool {
        guard let parsed = URL(string: input),
              let scheme = parsed.scheme?.lowercased(),
              parsed.host != nil
        else { return false }
        return scheme == "http" || scheme == "https"
    }
}
