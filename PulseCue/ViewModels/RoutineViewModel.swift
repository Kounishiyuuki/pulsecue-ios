import Foundation
import SwiftData

@MainActor
class RoutineViewModel: ObservableObject {
    @Published var searchText = ""
    var modelContext: ModelContext?
    
    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }
    
    func createRoutine(name: String) -> Routine {
        let routine = Routine(name: name)
        modelContext?.insert(routine)
        try? modelContext?.save()
        return routine
    }
    
    func updateRoutine(_ routine: Routine, name: String) {
        routine.name = name
        try? modelContext?.save()
    }
    
    func deleteRoutine(_ routine: Routine) {
        modelContext?.delete(routine)
        try? modelContext?.save()
    }
    
    func duplicateRoutine(_ routine: Routine) -> Routine {
        let duplicate = Routine(name: "\(routine.name) (Copy)", isPinned: false)
        modelContext?.insert(duplicate)
        
        for step in routine.steps.sorted(by: { $0.order < $1.order }) {
            let newStep = Step(name: step.name, durationSeconds: step.durationSeconds, order: step.order)
            newStep.routine = duplicate
            duplicate.steps.append(newStep)
            modelContext?.insert(newStep)
        }
        
        try? modelContext?.save()
        return duplicate
    }
    
    func togglePin(_ routine: Routine) {
        routine.isPinned.toggle()
        try? modelContext?.save()
    }
    
    func addStep(to routine: Routine, name: String, durationSeconds: Int) {
        let order = routine.steps.count
        let step = Step(name: name, durationSeconds: durationSeconds, order: order)
        step.routine = routine
        routine.steps.append(step)
        modelContext?.insert(step)
        try? modelContext?.save()
    }
    
    func updateStep(_ step: Step, name: String, durationSeconds: Int) {
        step.name = name
        step.durationSeconds = durationSeconds
        try? modelContext?.save()
    }
    
    func deleteStep(_ step: Step) {
        modelContext?.delete(step)
        try? modelContext?.save()
    }
    
    func reorderSteps(in routine: Routine, from source: IndexSet, to destination: Int) {
        var sortedSteps = routine.steps.sorted(by: { $0.order < $1.order })
        sortedSteps.move(fromOffsets: source, toOffset: destination)
        
        for (index, step) in sortedSteps.enumerated() {
            step.order = index
        }
        
        try? modelContext?.save()
    }
}
