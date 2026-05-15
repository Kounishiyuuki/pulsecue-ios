//
//  GymCandidateSearchViewModel.swift
//  Pulse Cue
//
//  State machine for the gym candidate search screen. The view drives
//  the two text inputs as `@Published` properties and calls `search()`
//  on the user's explicit tap. Auto-search on keystroke is
//  intentionally NOT implemented — it makes MapKit quota use harder
//  to reason about and the UX expectation here is "type, then tap".
//

import Foundation
import Combine

@MainActor
final class GymCandidateSearchViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case searching
        case loaded([GymCandidate])
        case empty
        case error(String)
    }

    @Published var brand: String = ""
    @Published var branch: String = ""
    @Published private(set) var state: State = .idle

    private let service: GymCandidateSearchService
    private var currentTask: Task<Void, Never>?

    init(service: GymCandidateSearchService) {
        self.service = service
    }

    /// Whether the search button should be enabled. Requires at least
    /// one non-blank input (brand or branch) and a non-searching
    /// state.
    var canSearch: Bool {
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmedBrand.isEmpty || !trimmedBranch.isEmpty) && state != .searching
    }

    func search() {
        guard canSearch else { return }
        currentTask?.cancel()
        state = .searching
        let capturedBrand = brand
        let capturedBranch = branch
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await self.service.search(
                    brand: capturedBrand,
                    branch: capturedBranch
                )
                if Task.isCancelled { return }
                self.applyResult(.success(results))
            } catch {
                if Task.isCancelled { return }
                self.applyResult(.failure(error))
            }
        }
    }

    /// Used by tests that want to drive the same code path
    /// synchronously without juggling Task scheduling. The view always
    /// goes through `search()`.
    func searchSync() async {
        guard canSearch else { return }
        state = .searching
        do {
            let results = try await service.search(brand: brand, branch: branch)
            applyResult(.success(results))
        } catch {
            applyResult(.failure(error))
        }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    private func applyResult(_ result: Result<[GymCandidate], Error>) {
        switch result {
        case .success(let results):
            state = results.isEmpty ? .empty : .loaded(results)
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            state = .error(message)
        }
    }
}
