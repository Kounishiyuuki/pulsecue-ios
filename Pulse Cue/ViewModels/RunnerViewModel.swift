//
//  RunnerViewModel.swift
//  Pulse Cue
//
//  Created by Codex.
//

import Foundation
import SwiftData
import Combine
import UserNotifications

@MainActor
final class RunnerViewModel: ObservableObject {
    @Published private(set) var phase: RunnerPhase = .done
    @Published private(set) var currentStepIndex: Int = 0
    @Published private(set) var currentSetIndex: Int = 0
    @Published private(set) var restDeadline: Date?
    @Published private(set) var remainingSeconds: Int = 0
    @Published var needsAttention: Bool = false
    @Published private(set) var sessionId: UUID?
    @Published private(set) var routineId: UUID?
    @Published private(set) var isConfigured: Bool = false

    private var modelContext: ModelContext?
    private var routine: Routine?
    private var steps: [Step] = []
    private var session: Session?
    private var timer: Timer?

    let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func configure(modelContext: ModelContext) {
        guard !isConfigured else { return }
        self.modelContext = modelContext
        self.isConfigured = true
        restoreIfPossible()
    }

    func start(routine: Routine) {
        guard let modelContext else { return }
        stopTimer()
        needsAttention = false

        self.routine = routine
        self.routineId = routine.id
        self.steps = fetchSteps(routineId: routine.id)
        self.currentStepIndex = 0
        self.currentSetIndex = 0
        self.phase = .exercise
        self.restDeadline = nil
        self.remainingSeconds = 0

        let session = Session(routineId: routine.id, dayDate: DateUtils.startOfDay(Date()))
        modelContext.insert(session)
        self.session = session
        self.sessionId = session.id

        if steps.isEmpty {
            finishSession(completed: true)
            return
        }

        saveState()
    }

    func handle(action: RunnerAction) {
        switch action {
        case .complete:
            completeCurrent()
        case .skip:
            skipCurrent()
        case .extend:
            extendRest()
        case .back:
            goBack()
        }
    }

    func endSessionEarly() {
        finishSession(completed: false)
    }

    func appDidBecomeActive() {
        guard phase == .rest else { return }
        if let deadline = restDeadline, deadline > Date() {
            startTimer()
            scheduleRestNotification()
        } else {
            restDeadline = nil
            phase = .exercise
            signalAttentionIfNeeded()
            advanceAfterRest()
        }
    }

    func appDidEnterBackground() {
        saveState()
    }

    var currentStep: Step? {
        guard steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    var nextStep: Step? {
        let nextIndex = currentStepIndex + 1
        guard steps.indices.contains(nextIndex) else { return nil }
        return steps[nextIndex]
    }

    var isRunning: Bool {
        phase != .done && sessionId != nil
    }

    private func completeCurrent() {
        guard phase != .done else { return }
        if phase == .rest {
            finishRest()
            return
        }
        guard let step = currentStep else {
            finishSession(completed: true)
            return
        }

        recordStepResult(done: true)
        startRest(for: step)
    }

    private func skipCurrent() {
        guard phase != .done else { return }
        if phase == .rest {
            stopTimer()
            NotificationManager.shared.removeAllPending()
            restDeadline = nil
            advanceToNextStepSkippingSets()
            return
        }
        guard currentStep != nil else {
            finishSession(completed: true)
            return
        }
        recordStepResult(done: false)
        advanceToNextStepSkippingSets()
    }

    private func extendRest() {
        guard phase == .rest, let deadline = restDeadline else { return }
        restDeadline = deadline.addingTimeInterval(10)
        scheduleRestNotification()
        saveState()
        tick()
    }

    private func goBack() {
        guard phase != .done else { return }
        if phase == .rest {
            phase = .exercise
            restDeadline = nil
            stopTimer()
            saveState()
            return
        }

        if currentSetIndex > 0 {
            currentSetIndex -= 1
        } else if currentStepIndex > 0 {
            currentStepIndex -= 1
            currentSetIndex = max(0, (currentStep?.sets ?? 1) - 1)
        }
        saveState()
    }

    private func startRest(for step: Step) {
        if step.restSeconds <= 0 {
            advanceAfterRest()
            return
        }
        phase = .rest
        restDeadline = Date().addingTimeInterval(TimeInterval(step.restSeconds))
        startTimer()
        scheduleRestNotification()
        saveState()
    }

    private func finishRest() {
        restDeadline = nil
        stopTimer()
        advanceAfterRest()
    }

    private func advanceAfterRest() {
        guard let step = currentStep else {
            finishSession(completed: true)
            return
        }

        if currentSetIndex + 1 < step.sets {
            currentSetIndex += 1
        } else {
            currentSetIndex = 0
            currentStepIndex += 1
        }

        if currentStepIndex >= steps.count {
            finishSession(completed: true)
            return
        }

        phase = .exercise
        saveState()
    }

    private func advanceToNextStepSkippingSets() {
        currentSetIndex = 0
        currentStepIndex += 1

        if currentStepIndex >= steps.count {
            finishSession(completed: true)
            return
        }

        phase = .exercise
        saveState()
    }

    private func finishSession(completed: Bool) {
        guard let session else {
            resetState()
            return
        }

        session.endedAt = Date()
        session.status = completed ? .completed : .abandoned
        session.totalSeconds = Int(session.endedAt!.timeIntervalSince(session.startedAt))

        resetState()
    }

    private func resetState() {
        stopTimer()
        NotificationManager.shared.removeAllPending()
        phase = .done
        currentStepIndex = 0
        currentSetIndex = 0
        restDeadline = nil
        remainingSeconds = 0
        needsAttention = false
        sessionId = nil
        routineId = nil
        routine = nil
        steps = []
        session = nil
        RunnerPersistence.clear()
    }

    private func recordStepResult(done: Bool) {
        guard let modelContext, let sessionId, let step = currentStep else { return }
        let result = StepResult(sessionId: sessionId, stepId: step.id, setIndex: currentSetIndex, done: done)
        modelContext.insert(result)
    }

    private func fetchSteps(routineId: UUID) -> [Step] {
        guard let modelContext else { return [] }
        let descriptor = FetchDescriptor<Step>(
            predicate: #Predicate<Step> { $0.routineId == routineId },
            sortBy: [SortDescriptor(\Step.order, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func startTimer() {
        stopTimer()
        tick()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard phase == .rest, let deadline = restDeadline else {
            remainingSeconds = 0
            return
        }
        let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        remainingSeconds = remaining
        if remaining <= 0 {
            onRestFinished()
        }
    }

    private func onRestFinished() {
        stopTimer()
        NotificationManager.shared.removeAllPending()
        phase = .exercise
        restDeadline = nil
        signalAttentionIfNeeded()
        advanceAfterRest()
    }

    private func signalAttentionIfNeeded() {
        NotificationManager.shared.getAuthorizationStatus { [weak self] status in
            guard let self else { return }
            let authorized = (status == .authorized || status == .provisional)
            if !authorized || !self.settings.notificationsEnabled {
                self.needsAttention = true
                if self.settings.soundEnabled {
                    SoundHapticManager.playBeep()
                }
                if self.settings.hapticsEnabled {
                    SoundHapticManager.playHaptic()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.needsAttention = false
                }
            }
        }
    }

    private func scheduleRestNotification() {
        guard settings.notificationsEnabled, let deadline = restDeadline else { return }
        let sessionUUID = sessionId?.uuidString ?? UUID().uuidString
        NotificationManager.shared.getAuthorizationStatus { status in
            guard status == .authorized || status == .provisional else { return }
            let identifier = "rest.\(sessionUUID)"
            NotificationManager.shared.scheduleRestNotification(deadline: deadline, identifier: identifier)
        }
    }

    private func saveState() {
        guard let sessionId, let routineId else { return }
        let state = RunnerPersistentState(
            sessionId: sessionId,
            routineId: routineId,
            phase: phase,
            stepIndex: currentStepIndex,
            setIndex: currentSetIndex,
            restDeadline: restDeadline,
            lastUpdatedAt: Date()
        )
        RunnerPersistence.save(state)
    }

    private func restoreIfPossible() {
        guard let modelContext, let state = RunnerPersistence.load() else { return }

        let sessionDescriptor = FetchDescriptor<Session>(predicate: #Predicate<Session> { $0.id == state.sessionId })
        let routineDescriptor = FetchDescriptor<Routine>(predicate: #Predicate<Routine> { $0.id == state.routineId })

        guard let session = try? modelContext.fetch(sessionDescriptor).first,
              let routine = try? modelContext.fetch(routineDescriptor).first else {
            RunnerPersistence.clear()
            return
        }

        if session.status != .inProgress {
            RunnerPersistence.clear()
            return
        }

        self.session = session
        self.routine = routine
        self.sessionId = session.id
        self.routineId = routine.id
        self.steps = fetchSteps(routineId: routine.id)
        self.currentStepIndex = min(state.stepIndex, max(0, steps.count - 1))
        self.currentSetIndex = max(0, state.setIndex)
        self.phase = state.phase
        self.restDeadline = state.restDeadline
        self.remainingSeconds = 0

        if phase == .rest {
            if let deadline = restDeadline, deadline > Date() {
                startTimer()
                scheduleRestNotification()
            } else {
                restDeadline = nil
                phase = .exercise
                advanceAfterRest()
            }
        }
    }
}
