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
    @Published private(set) var currentReps: Int = 0
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
    private var restNotificationGeneration = 0
    private var attentionGeneration = 0
    private let notificationManager: any RunnerNotificationManaging

    let settings: SettingsStore

    init(
        settings: SettingsStore,
        notificationManager: (any RunnerNotificationManaging)? = nil
    ) {
        self.settings = settings
        self.notificationManager = notificationManager ?? NotificationManager.shared
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
        invalidateAttention()
        cancelRestNotification()

        self.routine = routine
        self.routineId = routine.id
        self.steps = fetchSteps(routineId: routine.id)
        self.currentStepIndex = 0
        self.currentSetIndex = 0
        self.currentReps = steps.first?.repsTarget ?? 0
        self.phase = .exercise
        self.restDeadline = nil
        self.remainingSeconds = 0

        let session = Session(routineId: routine.id, dayDate: DateUtils.startOfDay(Date()))
        modelContext.insert(session)
        self.session = session
        self.sessionId = session.id
        cancelRestNotification(for: session.id)

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

    func adjustCurrentReps(by adjustment: Int) {
        guard phase == .exercise, isRunning else { return }
        let (adjustedReps, overflowed) = currentReps.addingReportingOverflow(adjustment)
        guard !overflowed else { return }
        currentReps = max(0, adjustedReps)
        saveState()
    }

    func shortenRest() {
        adjustRest(by: -10)
    }

    func appDidBecomeActive() {
        guard phase == .rest else { return }
        if let deadline = restDeadline, deadline > Date() {
            startTimer()
            scheduleRestNotification()
        } else {
            restDeadline = nil
            phase = .exercise
            cancelRestNotification()
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

        recordStepResult(done: true, actualReps: currentReps)
        startRest(for: step)
    }

    private func skipCurrent() {
        guard phase != .done else { return }
        invalidateAttention()
        cancelRestNotification()
        if phase == .rest {
            stopTimer()
            restDeadline = nil
            advanceToNextStepSkippingSets()
            return
        }
        guard currentStep != nil else {
            finishSession(completed: true)
            return
        }
        recordStepResult(done: false, actualReps: nil)
        advanceToNextStepSkippingSets()
    }

    private func extendRest() {
        adjustRest(by: 10)
    }

    private func adjustRest(by adjustment: Int) {
        guard phase == .rest, let deadline = restDeadline else { return }
        let adjustedRemaining = max(0, deadline.timeIntervalSinceNow + TimeInterval(adjustment))
        restDeadline = Date().addingTimeInterval(adjustedRemaining)
        tick()
        guard phase == .rest else { return }
        scheduleRestNotification()
        saveState()
    }

    private func goBack() {
        guard phase != .done else { return }
        if phase == .rest {
            invalidateAttention()
            cancelRestNotification()
            phase = .exercise
            restDeadline = nil
            stopTimer()
            currentReps = restoredRepsForCurrentPosition()
            saveState()
            return
        }

        guard currentSetIndex > 0 || currentStepIndex > 0 else { return }
        invalidateAttention()
        cancelRestNotification()
        var moved = false
        if currentSetIndex > 0 {
            currentSetIndex -= 1
            moved = true
        } else if currentStepIndex > 0 {
            currentStepIndex -= 1
            currentSetIndex = max(0, (currentStep?.sets ?? 1) - 1)
            moved = true
        }
        guard moved else { return }
        currentReps = restoredRepsForCurrentPosition()
        saveState()
    }

    private func startRest(for step: Step) {
        invalidateAttention()
        if step.restSeconds <= 0 {
            cancelRestNotification()
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
        invalidateAttention()
        restDeadline = nil
        stopTimer()
        cancelRestNotification()
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
        currentReps = currentStep?.repsTarget ?? 0
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
        currentReps = currentStep?.repsTarget ?? 0
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
        cancelRestNotification()
        invalidateAttention()
        phase = .done
        currentStepIndex = 0
        currentSetIndex = 0
        currentReps = 0
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

    private func recordStepResult(done: Bool, actualReps: Int?) {
        guard let modelContext, let sessionId, let step = currentStep else { return }
        let stepId = step.id
        let setIndex = currentSetIndex
        let descriptor = FetchDescriptor<StepResult>(
            predicate: #Predicate<StepResult> {
                $0.sessionId == sessionId && $0.stepId == stepId && $0.setIndex == setIndex
            }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.done = done
            existing.actualReps = actualReps
            return
        }
        let result = StepResult(
            sessionId: sessionId,
            stepId: step.id,
            setIndex: currentSetIndex,
            done: done,
            actualReps: actualReps
        )
        modelContext.insert(result)
    }

    private func restoredRepsForCurrentPosition() -> Int {
        guard let modelContext, let sessionId, let step = currentStep else {
            return currentStep?.repsTarget ?? 0
        }
        let stepId = step.id
        let setIndex = currentSetIndex
        let descriptor = FetchDescriptor<StepResult>(
            predicate: #Predicate<StepResult> {
                $0.sessionId == sessionId && $0.stepId == stepId && $0.setIndex == setIndex
            }
        )
        let recordedReps = (try? modelContext.fetch(descriptor).first)?.actualReps
        return max(0, recordedReps ?? step.repsTarget)
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
        cancelRestNotification()
        phase = .exercise
        restDeadline = nil
        signalAttentionIfNeeded()
        advanceAfterRest()
    }

    private func signalAttentionIfNeeded() {
        guard let sessionId else { return }
        attentionGeneration &+= 1
        let generation = attentionGeneration
        notificationManager.getAuthorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.attentionGeneration,
                      self.phase == .exercise,
                      self.sessionId == sessionId
                else { return }
                let authorized = (status == .authorized || status == .provisional)
                guard !authorized || !self.settings.notificationsEnabled else { return }

                self.needsAttention = true
                if self.settings.soundEnabled {
                    SoundHapticManager.playBeep()
                }
                if self.settings.hapticsEnabled {
                    SoundHapticManager.playHaptic()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self,
                          generation == self.attentionGeneration,
                          self.phase == .exercise,
                          self.sessionId == sessionId
                    else { return }
                    self.needsAttention = false
                }
            }
        }
    }

    private func scheduleRestNotification() {
        guard let sessionId else { return }
        cancelRestNotification(for: sessionId)
        guard settings.notificationsEnabled, restDeadline != nil else { return }
        let generation = restNotificationGeneration
        notificationManager.getAuthorizationStatus { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.restNotificationGeneration,
                      self.phase == .rest,
                      self.sessionId == sessionId,
                      let deadline = self.restDeadline,
                      deadline > Date(),
                      self.settings.notificationsEnabled,
                      status == .authorized || status == .provisional
                else { return }
                self.notificationManager.scheduleRestNotification(
                    deadline: deadline,
                    identifier: self.restNotificationIdentifier(for: sessionId)
                ) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let registrationIsCurrent =
                            generation == self.restNotificationGeneration &&
                            self.phase == .rest &&
                            self.sessionId == sessionId &&
                            self.restDeadline == deadline &&
                            self.settings.notificationsEnabled
                        guard !registrationIsCurrent else { return }

                        self.notificationManager.removeNotification(
                            identifier: self.restNotificationIdentifier(for: sessionId)
                        )
                        let newerScheduleOwnsIdentifier =
                            self.phase == .rest &&
                            self.sessionId == sessionId &&
                            self.settings.notificationsEnabled &&
                            (self.restDeadline ?? .distantPast) > Date()
                        if newerScheduleOwnsIdentifier {
                            self.scheduleRestNotification()
                        }
                    }
                }
            }
        }
    }

    private func cancelRestNotification(for sessionId: UUID? = nil) {
        restNotificationGeneration &+= 1
        guard let sessionId = sessionId ?? self.sessionId else { return }
        notificationManager.removeNotification(identifier: restNotificationIdentifier(for: sessionId))
    }

    private func restNotificationIdentifier(for sessionId: UUID) -> String {
        "rest.\(sessionId.uuidString)"
    }

    private func invalidateAttention() {
        attentionGeneration &+= 1
        needsAttention = false
    }

    private func saveState() {
        guard let sessionId, let routineId else { return }
        let state = RunnerPersistentState(
            sessionId: sessionId,
            routineId: routineId,
            phase: phase,
            stepIndex: currentStepIndex,
            setIndex: currentSetIndex,
            currentReps: currentReps,
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
            cancelRestNotification(for: state.sessionId)
            RunnerPersistence.clear()
            return
        }

        if session.status != .inProgress {
            cancelRestNotification(for: state.sessionId)
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
        self.currentReps = max(0, state.currentReps ?? currentStep?.repsTarget ?? 0)
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
                cancelRestNotification(for: session.id)
                advanceAfterRest()
            }
        }
    }
}
