import Foundation
import SwiftData

@MainActor
class HealthViewModel: ObservableObject {
    var modelContext: ModelContext?
    
    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }
    
    func getTodayLog() -> DayLog? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return nil
        }
        
        let descriptor = FetchDescriptor<DayLog>(
            predicate: #Predicate { log in
                log.date >= today && log.date < tomorrow
            }
        )
        
        return try? modelContext?.fetch(descriptor).first
    }
    
    func getOrCreateTodayLog() -> DayLog {
        if let existing = getTodayLog() {
            return existing
        }
        
        let log = DayLog(date: Date())
        modelContext?.insert(log)
        try? modelContext?.save()
        return log
    }
    
    func updateLog(_ log: DayLog, caloriesIntake: Double? = nil, caloriesExercise: Double? = nil, sleepHours: Double? = nil, weightKg: Double? = nil) {
        if let intake = caloriesIntake {
            log.caloriesIntake = intake
        }
        if let exercise = caloriesExercise {
            log.caloriesExercise = exercise
        }
        if let sleep = sleepHours {
            log.sleepHours = sleep
        }
        if let weight = weightKg {
            log.weightKg = weight
        }
        
        try? modelContext?.save()
    }
    
    func getRecentLogs(days: Int = 7) -> [DayLog] {
        let calendar = Calendar.current
        let endDate = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -days, to: endDate) else {
            return []
        }
        
        let descriptor = FetchDescriptor<DayLog>(
            predicate: #Predicate { log in
                log.date >= startDate && log.date <= endDate
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        
        return (try? modelContext?.fetch(descriptor)) ?? []
    }
}
