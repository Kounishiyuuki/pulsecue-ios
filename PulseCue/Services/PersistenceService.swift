import Foundation

class PersistenceService {
    static let shared = PersistenceService()
    
    private init() {}
    
    // Runner state keys
    private let runnerRoutineIdKey = "runnerRoutineId"
    private let runnerCurrentStepIndexKey = "runnerCurrentStepIndex"
    private let runnerDeadlineDateKey = "runnerDeadlineDate"
    private let runnerIsRunningKey = "runnerIsRunning"
    private let runnerElapsedSecondsKey = "runnerElapsedSeconds"
    
    // Save runner state
    func saveRunnerState(routineId: UUID?, currentStepIndex: Int, deadlineDate: Date?, isRunning: Bool, elapsedSeconds: Int) {
        if let routineId = routineId {
            UserDefaults.standard.set(routineId.uuidString, forKey: runnerRoutineIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: runnerRoutineIdKey)
        }
        
        UserDefaults.standard.set(currentStepIndex, forKey: runnerCurrentStepIndexKey)
        UserDefaults.standard.set(isRunning, forKey: runnerIsRunningKey)
        UserDefaults.standard.set(elapsedSeconds, forKey: runnerElapsedSecondsKey)
        
        if let deadlineDate = deadlineDate {
            UserDefaults.standard.set(deadlineDate, forKey: runnerDeadlineDateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: runnerDeadlineDateKey)
        }
    }
    
    // Load runner state
    func loadRunnerState() -> (routineId: UUID?, currentStepIndex: Int, deadlineDate: Date?, isRunning: Bool, elapsedSeconds: Int) {
        let routineIdString = UserDefaults.standard.string(forKey: runnerRoutineIdKey)
        let routineId = routineIdString.flatMap { UUID(uuidString: $0) }
        let currentStepIndex = UserDefaults.standard.integer(forKey: runnerCurrentStepIndexKey)
        let deadlineDate = UserDefaults.standard.object(forKey: runnerDeadlineDateKey) as? Date
        let isRunning = UserDefaults.standard.bool(forKey: runnerIsRunningKey)
        let elapsedSeconds = UserDefaults.standard.integer(forKey: runnerElapsedSecondsKey)
        
        return (routineId, currentStepIndex, deadlineDate, isRunning, elapsedSeconds)
    }
    
    // Clear runner state
    func clearRunnerState() {
        UserDefaults.standard.removeObject(forKey: runnerRoutineIdKey)
        UserDefaults.standard.removeObject(forKey: runnerCurrentStepIndexKey)
        UserDefaults.standard.removeObject(forKey: runnerDeadlineDateKey)
        UserDefaults.standard.removeObject(forKey: runnerIsRunningKey)
        UserDefaults.standard.removeObject(forKey: runnerElapsedSecondsKey)
    }
}
