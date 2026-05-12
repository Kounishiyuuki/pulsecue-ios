import Foundation
import SwiftData
import Combine

enum RunnerState {
    case idle
    case running
    case resting
}

@MainActor
class RunnerViewModel: ObservableObject {
    @Published var currentRoutine: Routine?
    @Published var currentStepIndex = 0
    @Published var state: RunnerState = .idle
    @Published var deadlineDate: Date?
    @Published var elapsedSeconds = 0
    @Published var remainingSeconds = 0
    
    private var timer: Timer?
    private let notificationService = NotificationService.shared
    private let hapticService = HapticService.shared
    private let audioService = AudioService.shared
    private let persistenceService = PersistenceService.shared
    
    var currentStep: Step? {
        guard let routine = currentRoutine, currentStepIndex < routine.steps.count else { return nil }
        return routine.steps.sorted(by: { $0.order < $1.order })[currentStepIndex]
    }
    
    var nextStep: Step? {
        guard let routine = currentRoutine else { return nil }
        let sortedSteps = routine.steps.sorted(by: { $0.order < $1.order })
        let nextIndex = currentStepIndex + 1
        guard nextIndex < sortedSteps.count else { return nil }
        return sortedSteps[nextIndex]
    }
    
    func startRoutine(_ routine: Routine) {
        currentRoutine = routine
        currentStepIndex = 0
        elapsedSeconds = 0
        state = .running
        
        if let step = currentStep {
            startStep(step)
        }
        
        saveState()
    }
    
    func restoreState(modelContext: ModelContext) {
        let savedState = persistenceService.loadRunnerState()
        
        guard let routineId = savedState.routineId else { return }
        
        // Fetch the routine from SwiftData
        let descriptor = FetchDescriptor<Routine>(predicate: #Predicate { $0.id == routineId })
        guard let routine = try? modelContext.fetch(descriptor).first else { return }
        
        currentRoutine = routine
        currentStepIndex = savedState.currentStepIndex
        deadlineDate = savedState.deadlineDate
        elapsedSeconds = savedState.elapsedSeconds
        
        if savedState.isRunning {
            // Check if we should still be running
            if let deadline = deadlineDate, deadline > Date() {
                state = .resting
                updateRemainingTime()
                startTimer()
            } else {
                state = .running
            }
        }
    }
    
    private func startStep(_ step: Step) {
        deadlineDate = Date().addingTimeInterval(TimeInterval(step.durationSeconds))
        remainingSeconds = step.durationSeconds
        
        state = .resting
        startTimer()
        
        // Schedule notification for step completion
        notificationService.scheduleNotification(
            title: "Step Complete",
            body: "\(step.name) finished!",
            date: deadlineDate!
        )
        
        // Play beep and haptic
        audioService.playBeep()
        hapticService.impact()
        
        saveState()
    }
    
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateRemainingTime()
            }
        }
    }
    
    private func updateRemainingTime() {
        guard let deadline = deadlineDate else { return }
        
        let remaining = deadline.timeIntervalSinceNow
        remainingSeconds = max(0, Int(remaining))
        
        if remainingSeconds == 0 {
            completeCurrentStep()
        }
        
        saveState()
    }
    
    func completeCurrentStep() {
        timer?.invalidate()
        
        guard let routine = currentRoutine else { return }
        let sortedSteps = routine.steps.sorted(by: { $0.order < $1.order })
        
        if currentStepIndex < sortedSteps.count - 1 {
            currentStepIndex += 1
            elapsedSeconds = 0
            state = .running
            
            // Trigger haptic and sound for step change
            hapticService.notification(.success)
            audioService.playBeep()
            
            saveState()
        } else {
            // Routine complete
            stop()
            hapticService.notification(.success)
        }
    }
    
    func skipCurrentStep() {
        completeCurrentStep()
    }
    
    func addTenSeconds() {
        guard let deadline = deadlineDate else { return }
        deadlineDate = deadline.addingTimeInterval(10)
        
        // Reschedule notification
        notificationService.cancelAllNotifications()
        if let step = currentStep {
            notificationService.scheduleNotification(
                title: "Step Complete",
                body: "\(step.name) finished!",
                date: deadlineDate!
            )
        }
        
        updateRemainingTime()
        hapticService.impact(.light)
    }
    
    func goBack() {
        if currentStepIndex > 0 {
            timer?.invalidate()
            currentStepIndex -= 1
            elapsedSeconds = 0
            state = .running
            hapticService.impact(.light)
            saveState()
        }
    }
    
    func startCurrentStep() {
        guard let step = currentStep else { return }
        startStep(step)
    }
    
    func stop() {
        timer?.invalidate()
        currentRoutine = nil
        currentStepIndex = 0
        state = .idle
        deadlineDate = nil
        elapsedSeconds = 0
        remainingSeconds = 0
        notificationService.cancelAllNotifications()
        persistenceService.clearRunnerState()
    }
    
    private func saveState() {
        persistenceService.saveRunnerState(
            routineId: currentRoutine?.id,
            currentStepIndex: currentStepIndex,
            deadlineDate: deadlineDate,
            isRunning: state == .resting,
            elapsedSeconds: elapsedSeconds
        )
    }
}
