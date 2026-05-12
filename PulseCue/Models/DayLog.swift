import Foundation
import SwiftData

@Model
final class DayLog {
    var id: UUID
    var date: Date
    var caloriesIntake: Double
    var caloriesExercise: Double
    var sleepHours: Double
    var weightKg: Double?
    
    var balance: Double {
        caloriesIntake - caloriesExercise
    }
    
    init(id: UUID = UUID(), date: Date = Date(), caloriesIntake: Double = 0, caloriesExercise: Double = 0, sleepHours: Double = 0, weightKg: Double? = nil) {
        self.id = id
        self.date = date
        self.caloriesIntake = caloriesIntake
        self.caloriesExercise = caloriesExercise
        self.sleepHours = sleepHours
        self.weightKg = weightKg
    }
}
